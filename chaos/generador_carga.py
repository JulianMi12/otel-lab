#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Generador de carga de un solo proceso.

Sustituye al bucle de `curl` en segundo plano que usaba comun.sh. El motivo no
es elegancia sino que el anterior no funcionaba de forma fiable en este
entorno: lanzaba un proceso nuevo por peticion -unos mil en dos minutos- y Git
Bash sobre Windows acababa agotando los recursos de fork:

    dofork: child -1 - forked process died unexpectedly, exit code 0xC0000142
    comun.sh: fork: Resource temporarily unavailable

El experimento moria a mitad de la fase de linea base, de forma intermitente y
dependiendo de la carga de la maquina. Un fallo que parece aleatorio cuesta
mucho mas de diagnosticar que uno constante.

Aqui todo ocurre en un proceso con un pool de conexiones reutilizado, que
ademas es mas representativo de un cliente real: un navegador tampoco abre una
conexion TCP nueva por peticion.

Uso:
    python chaos/generador_carga.py --rps 8 --objetivo http://localhost:8000
    kill <pid>        # termina de forma limpia
"""

import argparse
import os
import random
import signal
import sys
import threading
import time
import urllib.error
import urllib.request

_parar = threading.Event()


def _senal(_firma, _marco):
    _parar.set()


def _trabajador(objetivo, intervalo, pedidos, cabecera, contador, cerrojo):
    """
    Un hilo emisor. Mantiene su propio opener para reutilizar la conexion TCP:
    abrir una por peticion mediria el handshake en vez del servicio.
    """
    opener = urllib.request.build_opener()
    siguiente = time.monotonic()

    while not _parar.is_set():
        pedido = random.choice(pedidos)
        peticion = urllib.request.Request(objetivo + "/order/" + pedido)
        if cabecera:
            nombre, _, valor = cabecera.partition(":")
            peticion.add_header(nombre.strip(), valor.strip())

        resultado = "ok"
        try:
            with opener.open(peticion, timeout=25) as resp:
                resp.read()
        except urllib.error.HTTPError:
            # Un 5xx es un resultado del experimento, no un fallo del
            # generador: se cuenta y se sigue.
            resultado = "error_http"
        except Exception:
            resultado = "error_red"

        with cerrojo:
            contador["enviadas"] += 1
            contador[resultado] = contador.get(resultado, 0) + 1

        # Jitter pequeno: evita que todos los hilos caigan en el mismo instante
        # del ciclo de scrape, lo que daria una serie en forma de sierra que no
        # se parece a ningun trafico real.
        siguiente += intervalo
        espera = siguiente + random.uniform(-0.02, 0.02) - time.monotonic()
        if espera > 0:
            _parar.wait(espera)
        else:
            # El hilo va por detras del ritmo pedido. Se reancla el reloj para
            # no acumular una deuda que luego se descargaria en una rafaga.
            siguiente = time.monotonic()


def generar(objetivo, rps, pedidos, cabecera, concurrencia):
    """
    Reparte el ritmo pedido entre varios hilos.

    Con un solo hilo el generador es de lazo cerrado: no puede emitir mas
    rapido de lo que el servicio responde. Con 250 ms de latencia, pedir 8
    req/s daba 3,2 reales, y la diferencia no aparecia en ningun sitio salvo
    comparando con Prometheus. Peor aun, un generador asi NUNCA produce
    encolamiento, que es justo lo que un experimento de caos necesita observar.

    La concurrencia por defecto se calcula para que cada hilo tenga holgura
    suficiente incluso si la latencia se triplica durante el fallo inyectado.
    """
    intervalo_por_hilo = concurrencia / rps
    contador = {"enviadas": 0}
    cerrojo = threading.Lock()

    hilos = [
        threading.Thread(
            target=_trabajador,
            args=(objetivo, intervalo_por_hilo, pedidos, cabecera, contador, cerrojo),
            daemon=True,
        )
        for _ in range(concurrencia)
    ]

    for h in hilos:
        h.start()
    for h in hilos:
        h.join()

    return contador


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--objetivo", default=os.environ.get("SERVICE_A", "http://localhost:8000"))
    p.add_argument("--rps", type=float, default=8.0)
    p.add_argument("--pedidos", type=int, default=40,
                   help="numero de IDs distintos entre los que repartir la carga")
    p.add_argument("--cabecera", default="",
                   help="cabecera extra, p. ej. 'x-chaos: e1'")
    p.add_argument("--concurrencia", type=int, default=0,
                   help="hilos emisores; 0 los calcula a partir del ritmo pedido")
    args = p.parse_args()

    signal.signal(signal.SIGTERM, _senal)
    signal.signal(signal.SIGINT, _senal)

    pedidos = ["ORD-%04d" % n for n in range(1, args.pedidos + 1)]

    # Regla practica: un hilo por cada 2 req/s pedidas, minimo 4. Deja margen
    # para que el ritmo se sostenga aunque la latencia se triplique durante el
    # fallo, que es exactamente cuando el generador no debe ser el cuello de
    # botella.
    concurrencia = args.concurrencia or max(4, int(args.rps / 2) + 1)

    inicio = time.monotonic()
    contador = generar(args.objetivo.rstrip("/"), args.rps, pedidos,
                       args.cabecera, concurrencia)
    duracion = time.monotonic() - inicio

    enviadas = contador.get("enviadas", 0)
    print("generador detenido: %d peticiones en %.0f s (%.1f req/s reales) "
          "— %d ok, %d con 5xx, %d sin respuesta  [%d hilos]"
          % (enviadas, duracion, enviadas / duracion if duracion else 0,
             contador.get("ok", 0), contador.get("error_http", 0),
             contador.get("error_red", 0), concurrencia),
          file=sys.stderr)


if __name__ == "__main__":
    main()
