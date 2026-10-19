# Seguimiento venta

## Alcance

Registra el resultado de un ofrecimiento de medicamentos sin crear una venta,
un despacho o un movimiento de inventario.

## Captura publica

- `index.html` ofrece la accion **Registrar resultado** sin solicitar PIN.
- Los campos obligatorios son expediente, resultado y motivo.
- El comentario es obligatorio cuando el motivo es `Otro`.
- La fecha y hora se generan en PostgreSQL.
- La RPC publica solo permite crear registros y consultar motivos activos.
- La tabla no concede lectura ni escritura directa a `anon` o `authenticated`.
- Una clave de idempotencia y una ventana de dos minutos absorben dobles envios.
- El navegador conserva hasta 50 comprobantes no predecibles y puede consultar
  solamente esos registros durante siete dias.

## Administracion

El tab **Seguimiento venta** de `dashboard.html` requiere una sesion Admin y
permite:

- consultar indicadores por periodo;
- filtrar registros;
- exportar CSV;
- crear o corregir registros;
- anular y restaurar sin borrar el historico;
- crear, renombrar, ordenar y desactivar motivos.

Las modificaciones administrativas quedan registradas en
`sales_follow_up_audit`. Los motivos guardan una copia de su nombre en cada
evento para que una edicion posterior no cambie la lectura historica.

## Metricas

- **Registros:** eventos activos del periodo.
- **Pacientes unicos:** expedientes distintos con al menos un evento activo.
- **Sin compra:** ofrecimientos cuyo resultado fue no comprar medicamentos.
- **Compra parcial:** ofrecimientos donde el paciente compro algunos productos.

No se calcula una tasa de conversion porque el sistema aun no registra el total
de ofrecimientos realizados.

## Base de datos

La migracion se encuentra en `supabase/sql/088_sales_follow_up.sql`.
