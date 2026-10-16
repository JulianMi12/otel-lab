# ════════════════════════════════════════════════════════════════════════════
# Modulo C — Observabilidad de red y seguridad en AWS
#
# El equivalente de lo que seguridad.tf hace en GCP, con los servicios nativos
# de AWS. Compararlos lado a lado es uno de los objetivos del laboratorio, y
# la comparacion arroja una diferencia de diseno que conviene nombrar:
#
#   GCP  Los Flow Logs van a Cloud Logging, que ya es el destino de todo lo
#        demas. Una sola consulta puede cruzar un flujo de red con un log de
#        aplicacion, porque viven en el mismo sitio.
#
#   AWS  Los Flow Logs van a CloudWatch Logs, GuardDuty tiene su propia
#        consola, Security Hub otra, y las trazas estan en X-Ray. Cada pieza
#        es solida; lo que cuesta es cruzarlas. Este archivo lo resuelve
#        enviando TODO a CloudWatch Logs y definiendo ahi las consultas, que
#        es lo mas parecido a un panel unico que se puede montar sin pagar
#        una herramienta de terceros.
#
# COSTE: los servicios de este archivo tienen coste por volumen. Con
# `habilitar_seguridad_avanzada = false` quedan fuera GuardDuty y Security Hub,
# que son los dos que pueden crecer, y se conservan los Flow Logs, que son los
# que producen la senal que el modulo necesita.
# ════════════════════════════════════════════════════════════════════════════

# ════════════════════════════════════════════════════════════════════════════
# VPC Flow Logs
# ════════════════════════════════════════════════════════════════════════════
resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/aws/vpc/${local.nombre}/flow-logs"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  name               = "${local.nombre}-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "escribir-flow-logs"
  role = aws_iam_role.flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
      ]
      Resource = "${aws_cloudwatch_log_group.flow_logs.arn}:*"
    }]
  })
}

resource "aws_flow_log" "vpc" {
  log_destination = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn    = aws_iam_role.flow_logs.arn
  vpc_id          = aws_vpc.principal.id

  # ALL, no solo REJECT. Registrar unicamente los rechazos abarata el log pero
  # deja ciego el analisis de exfiltracion: una conexion de salida hacia un
  # destino no habitual es ACCEPT, no REJECT, y es precisamente la que
  # interesa detectar.
  traffic_type = "ALL"

  max_aggregation_interval = 60

  # Formato personalizado. El formato por defecto no incluye ni la region, ni
  # el nombre del subservicio, ni los flow-direction, y esos tres campos son
  # los que permiten distinguir trafico este-oeste de norte-sur sin tener que
  # resolver IPs a mano.
  log_format = join(" ", [
    "$${version}", "$${vpc-id}", "$${subnet-id}", "$${instance-id}",
    "$${interface-id}", "$${account-id}", "$${type}",
    "$${srcaddr}", "$${srcport}", "$${dstaddr}", "$${dstport}",
    "$${pkt-srcaddr}", "$${pkt-dstaddr}", "$${protocol}",
    "$${bytes}", "$${packets}", "$${start}", "$${end}",
    "$${action}", "$${tcp-flags}", "$${log-status}",
    "$${flow-direction}", "$${traffic-path}",
  ])

  tags = merge(var.tags, { Name = "${local.nombre}-flow-logs" })
}

# ════════════════════════════════════════════════════════════════════════════
# Metricas derivadas de los Flow Logs
#
# El equivalente de los log-based metrics de GCP. La misma idea: convertir
# texto en serie temporal para poder graficar y alertar, y dejar que el log
# crudo caduque antes que la metrica.
# ════════════════════════════════════════════════════════════════════════════
resource "aws_cloudwatch_log_metric_filter" "conexiones_rechazadas" {
  name           = "${local.nombre}-conexiones-rechazadas"
  log_group_name = aws_cloudwatch_log_group.flow_logs.name

  # El patron posicional depende del log_format de arriba: el campo 19 es
  # `action`. Si se cambia el formato hay que ajustar este patron, y por eso
  # ambos viven en el mismo archivo.
  pattern = "[version, vpc_id, subnet_id, instance_id, interface_id, account_id, type, srcaddr, srcport, dstaddr, dstport, pkt_srcaddr, pkt_dstaddr, protocol, bytes, packets, start, end, action=REJECT, tcp_flags, log_status, flow_direction, traffic_path]"

  metric_transformation {
    name      = "ConexionesRechazadas"
    namespace = "OtelLab/Seguridad"
    value     = "1"
    unit      = "Count"

    default_value = 0
  }
}

resource "aws_cloudwatch_log_metric_filter" "salida_bytes" {
  name           = "${local.nombre}-salida-bytes"
  log_group_name = aws_cloudwatch_log_group.flow_logs.name

  # flow_direction=egress y trafico aceptado. El valor de la metrica son los
  # BYTES, no el numero de lineas: una exfiltracion es pocas conexiones con
  # mucho volumen, y contando conexiones pasaria desapercibida.
  pattern = "[version, vpc_id, subnet_id, instance_id, interface_id, account_id, type, srcaddr, srcport, dstaddr, dstport, pkt_srcaddr, pkt_dstaddr, protocol, bytes, packets, start, end, action=ACCEPT, tcp_flags, log_status, flow_direction=egress, traffic_path]"

  metric_transformation {
    name          = "BytesDeSalida"
    namespace     = "OtelLab/Seguridad"
    value         = "$bytes"
    unit          = "Bytes"
    default_value = 0
  }
}

resource "aws_cloudwatch_log_metric_filter" "puertos_sensibles" {
  name           = "${local.nombre}-puertos-sensibles"
  log_group_name = aws_cloudwatch_log_group.flow_logs.name

  # Intentos hacia SSH y RDP. Ninguna task de este laboratorio deberia recibir
  # ni originar trafico por esos puertos, asi que cualquier valor distinto de
  # cero merece una mirada.
  pattern = "[version, vpc_id, subnet_id, instance_id, interface_id, account_id, type, srcaddr, srcport, dstaddr, dstport=22 || dstport=3389, pkt_srcaddr, pkt_dstaddr, protocol, bytes, packets, start, end, action, tcp_flags, log_status, flow_direction, traffic_path]"

  metric_transformation {
    name          = "IntentosPuertosSensibles"
    namespace     = "OtelLab/Seguridad"
    value         = "1"
    unit          = "Count"
    default_value = 0
  }
}

# ════════════════════════════════════════════════════════════════════════════
# Alarmas
# ════════════════════════════════════════════════════════════════════════════
resource "aws_sns_topic" "seguridad" {
  name = "${local.nombre}-seguridad"
  tags = var.tags
}

resource "aws_sns_topic_subscription" "seguridad_correo" {
  count = var.email_alertas == "" ? 0 : 1

  topic_arn = aws_sns_topic.seguridad.arn
  protocol  = "email"
  endpoint  = var.email_alertas

  # AWS envia un correo de confirmacion y la suscripcion queda en estado
  # "pending" hasta que alguien pulsa el enlace. Terraform da el recurso por
  # creado igualmente, asi que un `apply` limpio NO garantiza que las alarmas
  # lleguen a ninguna parte: hay que confirmar desde el correo.
}

resource "aws_cloudwatch_metric_alarm" "escaneo_de_puertos" {
  alarm_name          = "${local.nombre}-escaneo-de-puertos"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 20
  period              = 300
  statistic           = "Sum"

  metric_name = "ConexionesRechazadas"
  namespace   = "OtelLab/Seguridad"

  alarm_description = join(" ", [
    "Mas de 20 conexiones rechazadas en cinco minutos.",
    "En reposo esta metrica vale cero: los security groups solo permiten los",
    "puertos que los servicios usan, y el trafico legitimo nunca intenta otros.",
    "Un valor sostenido indica o un escaneo, o un despliegue nuevo que intenta",
    "hablar por un puerto que nadie abrio. Lo segundo es mas probable; mirar",
    "primero si hubo un despliegue reciente.",
  ])

  alarm_actions = [aws_sns_topic.seguridad.arn]
  ok_actions    = [aws_sns_topic.seguridad.arn]

  # Sin esto, los periodos sin ninguna conexion rechazada dejarian la alarma
  # en INSUFFICIENT_DATA en vez de en OK, que es el estado correcto cuando la
  # ausencia de datos significa "no ha pasado nada malo".
  treat_missing_data = "notBreaching"

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "exfiltracion" {
  alarm_name          = "${local.nombre}-salida-inusual"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = var.umbral_exfiltracion_mb * 1024 * 1024
  period              = 300
  statistic           = "Sum"

  metric_name = "BytesDeSalida"
  namespace   = "OtelLab/Seguridad"

  alarm_description = join(" ", [
    "El volumen de salida supera el umbral durante dos periodos seguidos.",
    "La salida legitima de este despliegue son las exportaciones a X-Ray y",
    "CloudWatch mas la descarga de imagenes de ECR. Antes de escalar, cruzar",
    "con la consulta 'salida-por-destino' de CloudWatch Logs Insights para ver",
    "hacia donde va.",
  ])

  alarm_actions      = [aws_sns_topic.seguridad.arn]
  treat_missing_data = "notBreaching"

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "puertos_sensibles" {
  alarm_name          = "${local.nombre}-puertos-sensibles"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 0
  period              = 300
  statistic           = "Sum"

  metric_name = "IntentosPuertosSensibles"
  namespace   = "OtelLab/Seguridad"

  alarm_description = join(" ", [
    "Se ha observado trafico hacia SSH (22) o RDP (3389) dentro de la VPC.",
    "Ninguna task de este laboratorio usa esos puertos, ni como origen ni como",
    "destino: cualquier valor distinto de cero es anomalo por definicion.",
  ])

  alarm_actions      = [aws_sns_topic.seguridad.arn]
  treat_missing_data = "notBreaching"

  tags = var.tags
}

# ════════════════════════════════════════════════════════════════════════════
# Consultas guardadas de CloudWatch Logs Insights
#
# El panel de AWS no puede mostrar la misma riqueza que el de GCP sin pagar
# una herramienta de terceros, asi que la investigacion se hace con consultas.
# Guardarlas en Terraform, y no en la cabeza de quien estuvo de guardia la vez
# anterior, es lo que las hace reutilizables a las tres de la madrugada.
# ════════════════════════════════════════════════════════════════════════════
resource "aws_cloudwatch_query_definition" "quien_habla_con_quien" {
  name = "${local.nombre}/red/quien-habla-con-quien"

  log_group_names = [aws_cloudwatch_log_group.flow_logs.name]

  query_string = <<-QUERY
    fields @timestamp, srcaddr, dstaddr, dstport, bytes, action
    | filter action = "ACCEPT"
    | stats sum(bytes) as total_bytes, count(*) as conexiones
        by srcaddr, dstaddr, dstport
    | sort total_bytes desc
    | limit 50
  QUERY
}

resource "aws_cloudwatch_query_definition" "salida_por_destino" {
  name = "${local.nombre}/red/salida-por-destino"

  log_group_names = [aws_cloudwatch_log_group.flow_logs.name]

  query_string = <<-QUERY
    fields @timestamp, dstaddr, dstport, bytes
    | filter flow_direction = "egress" and action = "ACCEPT"
    | stats sum(bytes) as bytes_enviados, count(*) as flujos by dstaddr, dstport
    | sort bytes_enviados desc
    | limit 30
  QUERY
}

resource "aws_cloudwatch_query_definition" "rechazos_por_puerto" {
  name = "${local.nombre}/red/rechazos-por-puerto"

  log_group_names = [aws_cloudwatch_log_group.flow_logs.name]

  query_string = <<-QUERY
    fields @timestamp, srcaddr, dstaddr, dstport
    | filter action = "REJECT"
    | stats count(*) as intentos by dstport, srcaddr
    | sort intentos desc
    | limit 30
  QUERY
}

# Esta es la consulta que cruza las dos mitades del laboratorio: parte de un
# trace_id de una traza con error y devuelve los logs de aplicacion que lo
# acompanan. Es el equivalente de lo que en GCP se hace con un clic desde
# Cloud Trace.
resource "aws_cloudwatch_query_definition" "logs_por_trace" {
  name = "${local.nombre}/correlacion/logs-de-una-traza"

  log_group_names = [aws_cloudwatch_log_group.telemetria.name]

  query_string = <<-QUERY
    fields @timestamp, trace_id, span_id, service, level, message
    | filter trace_id = "PEGAR_AQUI_EL_TRACE_ID"
    | sort @timestamp asc
    | limit 200
  QUERY
}

# ════════════════════════════════════════════════════════════════════════════
# GuardDuty y Security Hub
#
# El equivalente de Security Command Center. Opcionales porque son los unicos
# servicios de este archivo cuyo coste crece con el uso y no con el tiempo:
# GuardDuty cobra por volumen de Flow Logs y eventos de CloudTrail analizados,
# y Security Hub por comprobacion ejecutada.
#
# Para el laboratorio, treinta dias de prueba gratuita cubren de sobra la
# demostracion. Hay que acordarse de apagarlos:
#   aws securityhub disable-security-hub --profile uni
#   aws guardduty delete-detector --detector-id <id> --profile uni
# ════════════════════════════════════════════════════════════════════════════
resource "aws_guardduty_detector" "principal" {
  count = var.habilitar_seguridad_avanzada ? 1 : 0

  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"

  tags = var.tags
}

resource "aws_securityhub_account" "principal" {
  count = var.habilitar_seguridad_avanzada ? 1 : 0

  # Solo el estandar de AWS Foundational Security Best Practices. Habilitar
  # tambien CIS y PCI multiplica el numero de comprobaciones y, con el, el
  # coste, sin aportar hallazgos distintos en un entorno de laboratorio.
  enable_default_standards = true

  auto_enable_controls = true
}

# Los hallazgos de GuardDuty llegan a EventBridge; esta regla los reenvia al
# mismo topico de SNS que las alarmas de red, para que todo lo de seguridad
# entre por un unico canal.
resource "aws_cloudwatch_event_rule" "hallazgos_guardduty" {
  count = var.habilitar_seguridad_avanzada ? 1 : 0

  name        = "${local.nombre}-hallazgos-guardduty"
  description = "Reenvia los hallazgos de severidad media o superior"

  event_pattern = jsonencode({
    source      = ["aws.guardduty"]
    detail-type = ["GuardDuty Finding"]
    detail = {
      # 4.0 es el corte entre baja y media. Por debajo, GuardDuty genera
      # hallazgos informativos que en un laboratorio son casi todos ruido.
      severity = [{ numeric = [">=", 4.0] }]
    }
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "hallazgos_a_sns" {
  count = var.habilitar_seguridad_avanzada ? 1 : 0

  rule      = aws_cloudwatch_event_rule.hallazgos_guardduty[0].name
  target_id = "sns"
  arn       = aws_sns_topic.seguridad.arn
}

resource "aws_sns_topic_policy" "permitir_eventbridge" {
  count = var.habilitar_seguridad_avanzada ? 1 : 0

  arn = aws_sns_topic.seguridad.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "SNS:Publish"
      Resource  = aws_sns_topic.seguridad.arn
    }]
  })
}
