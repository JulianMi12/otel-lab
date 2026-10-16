"""
datastore.py - Acceso a datos con dos backends intercambiables.

    postgres  -> PostgreSQL via psycopg2 (entorno local y cualquier despliegue
                 que tenga una base de datos gestionada disponible)
    memoria   -> Estructuras en memoria con los mismos datos semilla

Por que existe el backend en memoria:

El despliegue en la nube de este laboratorio se hace SIN base de datos
gestionada, porque Cloud SQL es el unico recurso del stack con costo por hora
continuo. Sin un sustituto, los servicios no arrancarian en Cloud Run y no
habria nada que demostrar alli.

Con el backend en memoria el flujo de negocio completo sigue funcionando
-service-a consulta el pedido, llama a service-b, service-b consulta el
inventario- de modo que la propagacion de contexto W3C y las tres senales se
observan igual en Cloud Trace. La unica diferencia es que no hay spans
generados por la auto-instrumentacion de psycopg2; los custom spans de negocio
se emiten en ambos casos y declaran su origen en el atributo `db.system`.

La seleccion es automatica: si DATABASE_URL esta vacia, o si PostgreSQL no
responde tras varios intentos, se usa memoria. Tambien puede forzarse con
DATASTORE=memoria.
"""

import os
import threading
import time

# -----------------------------------------------------------------------------
# Datos semilla
# -----------------------------------------------------------------------------
# Replican exactamente lo que scripts/init-db.sql carga en PostgreSQL, para que
# el comportamiento observable sea el mismo con cualquiera de los dos backends.
PRODUCTOS = [
    ("laptop-pro", 250, 12, "WH-CENTRAL"),
    ("mouse-wireless", 980, 40, "WH-CENTRAL"),
    ("keyboard-mech", 120, 8, "WH-NORTE"),
    ("monitor-27", 45, 5, "WH-NORTE"),
    ("webcam-hd", 7, 2, "WH-SUR"),       # stock bajo
    ("dock-usbc", 3, 1, "WH-SUR"),       # stock bajo
    ("headset-anc", 0, 0, "WH-CENTRAL"),  # sin stock
    ("ssd-1tb", 400, 25, "WH-CENTRAL"),
]

ESTADOS = ["pending", "confirmed", "shipped", "delivered"]


def _pedidos_semilla():
    """Genera los 40 pedidos con la misma formula que init-db.sql."""
    pedidos = {}
    for gs in range(1, 41):
        pid = "ORD-" + str(gs).zfill(4)
        pedidos[pid] = {
            "id": pid,
            "product": PRODUCTOS[gs % 8][0],
            "quantity": 1 + (gs % 5),
            "status": ESTADOS[gs % 4],
            # float explicito: la columna NUMERIC de PostgreSQL llega como
            # decimal, y sin la conversion este backend devolveria int para los
            # precios sin parte fraccionaria. Los dos backends deben ser
            # indistinguibles para el codigo que los consume.
            "unit_price": round(float(50 + (gs * 37) % 1500), 2),
        }
    return pedidos


# -----------------------------------------------------------------------------
# Backend en memoria
# -----------------------------------------------------------------------------
class AlmacenMemoria:
    """Implementacion en memoria. Segura entre hilos mediante un lock."""

    tipo = "memoria"
    db_system = "memory"

    # Se declara la misma consulta que el backend SQL para que el span lleve
    # un `db.statement` equivalente con cualquiera de los dos backends.
    SQL_ANALITICA = (
        "SELECT product, COUNT(*), SUM(quantity), SUM(quantity * unit_price), "
        "AVG(quantity * unit_price), "
        "COUNT(*) FILTER (WHERE status = 'delivered') "
        "FROM orders WHERE product = ? GROUP BY product"
    )

    def __init__(self):
        self._lock = threading.Lock()
        self._pedidos = _pedidos_semilla()
        self._inventario = {
            p[0]: {
                "product": p[0],
                "available": p[1],
                "reserved": p[2],
                "warehouse": p[3],
            }
            for p in PRODUCTOS
        }

    def obtener_pedido(self, pedido_id):
        with self._lock:
            p = self._pedidos.get(pedido_id)
            if not p:
                return None
            return (
                p["id"],
                p["product"],
                p["quantity"],
                p["status"],
                p["unit_price"],
            )

    def listar_pedidos(self, limite=50):
        with self._lock:
            return sorted(self._pedidos.keys())[:limite]

    def obtener_inventario(self, producto_id):
        with self._lock:
            i = self._inventario.get(producto_id)
            if not i:
                return None
            return (i["product"], i["available"], i["reserved"], i["warehouse"])

    def reservar(self, producto_id, cantidad):
        # El lock reproduce la atomicidad que en PostgreSQL da la clausula
        # WHERE available >= cantidad: sin el, dos peticiones concurrentes
        # podrian reservar el mismo stock.
        with self._lock:
            i = self._inventario.get(producto_id)
            if not i or i["available"] < cantidad:
                return None
            i["available"] -= cantidad
            i["reserved"] += cantidad
            return (i["available"], i["reserved"])

    # -- Consultas analiticas (las consume data-service) --------------------

    def listar_productos(self, limite=50):
        """Catalogo con el stock agregado de cada producto."""
        with self._lock:
            return [
                (p["product"], p["available"], p["reserved"], p["warehouse"])
                for p in list(self._inventario.values())[:limite]
            ]

    def analitica_producto(self, producto_id):
        """
        Agrega los pedidos de un producto: unidades, importe y ticket medio.

        Es el equivalente en memoria de un SELECT con GROUP BY, calculado
        sobre los mismos datos semilla, de modo que el resultado coincide con
        el del backend PostgreSQL.
        """
        with self._lock:
            pedidos = [
                p for p in self._pedidos.values() if p["product"] == producto_id
            ]
            if not pedidos:
                return None

            unidades = sum(p["quantity"] for p in pedidos)
            importe = sum(p["quantity"] * p["unit_price"] for p in pedidos)
            entregados = sum(1 for p in pedidos if p["status"] == "delivered")

            return (
                producto_id,
                len(pedidos),
                unidades,
                round(importe, 2),
                round(importe / len(pedidos), 2),
                entregados,
            )

    def cerrar(self):
        pass


# -----------------------------------------------------------------------------
# Backend PostgreSQL
# -----------------------------------------------------------------------------
class AlmacenPostgres:
    """
    Implementacion sobre PostgreSQL con pool de conexiones.

    El pool evita pagar el handshake TCP y la autenticacion en cada peticion:
    ese costo dominaria la medicion del benchmark y se le atribuiria a
    OpenTelemetry una latencia que en realidad es de la base de datos.
    """

    tipo = "postgres"
    db_system = "postgresql"

    # Texto de la consulta analitica, que data-service publica como atributo
    # `db.statement` del span siguiendo las DB Semantic Conventions. El
    # parametro NO se interpola aqui: viaja como marcador y lo sustituye el
    # driver, de modo que el atributo de la traza nunca lleva datos de usuario.
    SQL_ANALITICA = (
        "SELECT product, COUNT(*) AS pedidos, SUM(quantity) AS unidades, "
        "SUM(quantity * unit_price) AS importe, "
        "AVG(quantity * unit_price) AS ticket_medio, "
        "COUNT(*) FILTER (WHERE status = 'delivered') AS entregados "
        "FROM orders WHERE product = %s GROUP BY product"
    )

    def __init__(self, dsn, minconn=2, maxconn=20):
        from psycopg2.pool import ThreadedConnectionPool

        self._pool = ThreadedConnectionPool(minconn=minconn, maxconn=maxconn, dsn=dsn)

    def obtener_pedido(self, pedido_id):
        conn = self._pool.getconn()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT id, product, quantity, status, unit_price "
                    "FROM orders WHERE id = %s",
                    (pedido_id,),
                )
                fila = cur.fetchone()
            return (
                (fila[0], fila[1], fila[2], fila[3], float(fila[4])) if fila else None
            )
        finally:
            self._pool.putconn(conn)

    def listar_pedidos(self, limite=50):
        conn = self._pool.getconn()
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT id FROM orders ORDER BY id LIMIT %s", (limite,))
                return [f[0] for f in cur.fetchall()]
        finally:
            self._pool.putconn(conn)

    def obtener_inventario(self, producto_id):
        conn = self._pool.getconn()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT product, available, reserved, warehouse "
                    "FROM inventory WHERE product = %s",
                    (producto_id,),
                )
                return cur.fetchone()
        finally:
            self._pool.putconn(conn)

    def reservar(self, producto_id, cantidad):
        conn = self._pool.getconn()
        try:
            with conn.cursor() as cur:
                # WHERE available >= cantidad evita la sobreventa bajo
                # concurrencia sin bloquear la tabla entera.
                cur.execute(
                    "UPDATE inventory SET available = available - %s, "
                    "reserved = reserved + %s "
                    "WHERE product = %s AND available >= %s "
                    "RETURNING available, reserved",
                    (cantidad, cantidad, producto_id, cantidad),
                )
                resultado = cur.fetchone()
            conn.commit()
            return resultado
        except Exception:
            conn.rollback()
            raise
        finally:
            self._pool.putconn(conn)

    # -- Consultas analiticas (las consume data-service) --------------------

    def listar_productos(self, limite=50):
        conn = self._pool.getconn()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT product, available, reserved, warehouse "
                    "FROM inventory ORDER BY product LIMIT %s",
                    (limite,),
                )
                return cur.fetchall()
        finally:
            self._pool.putconn(conn)

    def analitica_producto(self, producto_id):
        """Agregacion sobre los pedidos de un producto."""
        conn = self._pool.getconn()
        try:
            with conn.cursor() as cur:
                cur.execute(self.SQL_ANALITICA, (producto_id,))
                fila = cur.fetchone()
            if not fila:
                return None
            # NUMERIC llega como Decimal; se normaliza a float para que la
            # respuesta JSON sea identica con ambos backends.
            return (
                fila[0], int(fila[1]), int(fila[2]),
                round(float(fila[3]), 2), round(float(fila[4]), 2), int(fila[5]),
            )
        finally:
            self._pool.putconn(conn)

    def cerrar(self):
        self._pool.closeall()


# -----------------------------------------------------------------------------
# Seleccion del backend
# -----------------------------------------------------------------------------
def crear_almacen(logger, reintentos=8, espera=2.0):
    """
    Devuelve el almacen adecuado al entorno.

    Orden de decision:
      1. DATASTORE=memoria            -> memoria, sin intentar conectar
      2. DATABASE_URL vacia           -> memoria
      3. PostgreSQL accesible         -> postgres
      4. PostgreSQL inaccesible       -> memoria (degradacion, no caida)

    El ultimo caso es deliberado: un servicio que no arranca no produce
    telemetria, y en un laboratorio de observabilidad eso es peor que operar
    con datos de demostracion. La eleccion queda registrada en el log de
    arranque para que nunca sea una sorpresa silenciosa.
    """
    forzado = os.getenv("DATASTORE", "").strip().lower()
    dsn = os.getenv("DATABASE_URL", "").strip()

    if forzado == "memoria" or forzado == "memory":
        logger.info("Almacen en memoria (forzado por DATASTORE)")
        return AlmacenMemoria()

    if not dsn:
        logger.info("Almacen en memoria: DATABASE_URL no esta definida")
        return AlmacenMemoria()

    for intento in range(1, reintentos + 1):
        try:
            almacen = AlmacenPostgres(dsn)
            logger.info("Conectado a PostgreSQL", extra={"intento": intento})
            return almacen
        except Exception as exc:
            logger.warning(
                "PostgreSQL no disponible, reintentando",
                extra={"intento": intento, "total": reintentos, "error": str(exc)},
            )
            if intento < reintentos:
                time.sleep(espera)

    logger.warning(
        "PostgreSQL inaccesible tras %d intentos: se degrada a almacen en "
        "memoria para que el servicio siga emitiendo telemetria",
        reintentos,
    )
    return AlmacenMemoria()
