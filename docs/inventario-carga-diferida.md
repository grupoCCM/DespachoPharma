# Inventario: carga diferida por pestaña

## Objetivo

La pantalla `inventory-audit.html` mezcla cuatro usos distintos: conteo físico, ajuste puntual, control de diferencias y kardex. Antes cargaba todo al entrar, aunque el usuario solo necesitara iniciar o continuar un conteo. Eso podía hacer más lenta la entrada al módulo y crear sensación de bloqueo.

## Comportamiento actual

Al abrir Inventario se carga únicamente la pestaña activa por defecto: **Conteo físico**.

Las demás consultas se cargan cuando el usuario entra a la pestaña correspondiente:

| Pestaña | Carga principal | Momento de carga |
| --- | --- | --- |
| Conteo físico | Sesión vigente e ítems del conteo | Al abrir la pantalla y al entrar a la pestaña |
| Ajuste puntual | Conteos puntuales recientes | Al entrar a la pestaña |
| Diferencias | Pendientes, solventados y resumen del último conteo | Al entrar a la pestaña |
| Correcciones | Formulario de reclasificación | No carga datos iniciales; busca productos al digitar |
| Kardex | Movimientos recientes y productos con cambios | Al entrar a la pestaña o buscar |

## Reglas de refresco

- El botón **Actualizar** refresca la pestaña activa, no toda la pantalla.
- Si se aplica un ajuste de conteo, ajuste puntual o reclasificación, se marca como pendiente de recarga lo relacionado con diferencias y kardex.
- Si el usuario está viendo **Diferencias** o **Kardex** al momento de aplicar un cambio, esa información se recarga de inmediato.
- Si el usuario está en otra pestaña, la recarga pesada se pospone hasta que entre a **Diferencias** o **Kardex**.

## Consultas pesadas

Estas consultas se evitan durante el arranque inicial:

- `rpc_inventory_audit`
- `rpc_inventory_variance_control`
- `rpc_inventory_count_resolution_board`

Solo se ejecutan cuando hacen falta para **Diferencias** o **Kardex**.

## Impacto operativo

- Conteo físico abre más rápido.
- Los usuarios operativos no cargan auditoría administrativa que no necesitan.
- La información administrativa sigue disponible y se actualiza cuando se consulta o cuando una acción visible lo requiere.
- No cambia datos históricos, SQL ni reglas de inventario; es un cambio de UI/carga.

## Validación recomendada

1. Entrar a `inventory-audit.html`.
2. Confirmar que abre en **Conteo físico**.
3. Entrar a **Ajuste puntual** y validar que carga conteos recientes.
4. Entrar a **Diferencias** y validar pendientes/solventados.
5. Entrar a **Kardex**, buscar un producto y validar movimientos.
6. Aplicar un ajuste de prueba controlado y verificar que la pestaña visible se actualiza sin forzar toda la pantalla.
