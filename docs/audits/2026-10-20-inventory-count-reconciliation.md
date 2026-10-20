# Conciliacion excepcional del conteo fisico del 20/10/2026

## Alcance

Este informe documenta la conciliacion posterior al conteo fisico cerrado con
identificador `3d392c92-4b0d-4e17-911d-8c60ae1c7018`.

El conteo es evidencia inmutable. La conciliacion no modifica sus cantidades,
diferencias, notas, hallazgos, usuario ni fechas. Los saldos se corrigen mediante
movimientos posteriores y trazables en el Kardex.

## Fuentes contrastadas

- PDF `20261020_Conteo fisico Finalizado - Botiquin CCM.pdf`.
- `Compras por Articulo (2).xlsx`.
- `Ventas Netas por Articulo (10).xlsx`.
- `Resumen de Articulos Facturados (24).xlsx`.
- `Existencias en Inventario (Valorizado) (55).xlsx`, con existencia al 20/10/2026.
- Movimientos de cambio de producto de entrada y salida.
- Movimientos de salida por vencimiento.
- Kardex, snapshots, devoluciones, despachos y movimientos vigentes en Supabase.

## Metodo

1. Congelar como referencia los valores `expected_qty`, `counted_qty` y
   `variance_qty` del conteo cerrado.
2. Reconstruir por producto la ecuacion ERP: compras y entradas menos ventas,
   devoluciones, vencimientos y salidas.
3. Comparar esa ecuacion con el snapshot usado por la aplicacion y todos los
   movimientos posteriores al snapshot.
4. Clasificar cada diferencia por causa demostrada, sin inferir causas no
   respaldadas por documentos.
5. Aplicar solamente diferencias cerradas, mediante movimientos idempotentes
   con `source_event_key` unico y metadatos de evidencia.
6. Volver a comparar saldo actual, conteo original y pendientes no resueltos.

## Correcciones autorizadas

| Codigo | Diferencia | Clasificacion | Evidencia y tratamiento |
| --- | ---: | --- | --- |
| 765 | -15 | Error de integracion/importacion | La compra CF-1797 ya estaba incluida en la existencia base del 17/07/2026 y se agrego otra vez desde `Compras por Articulo (17).xlsx`. Movimiento correctivo posterior; no se elimina la compra. |
| 766 | -15 | Error de integracion/importacion | Mismo evento CF-1797. La importacion genero movimientos por 14 y 1 unidades sobre un saldo que ya incluia la compra. |
| 789 | -5 | Error de integracion/importacion | La compra CF-23050 ya estaba incluida en la existencia base y se importo nuevamente. |
| 790 | -5 | Error de integracion/importacion | Mismo evento CF-23050, duplicado respecto del saldo base. |
| 745 | -1 | Diferencia fisica confirmada | ERP y aplicacion conciliaban 4; el conteo encontro 3. No hay evidencia para atribuirla a un error matematico de la aplicacion. |
| 750 | -4 | Diferencia fisica confirmada | ERP y aplicacion conciliaban 27; el conteo encontro 23. La causa operativa especifica no esta demostrada. |
| 771 | -1 | Diferencia fisica confirmada | ERP y aplicacion conciliaban 2; el conteo encontro 1. La causa operativa especifica no esta demostrada. |

Total de ajuste verificado: **-46 unidades**.

Los movimientos usan el tipo `manual_count_adjust_out`, el origen
`count_session` y claves `count_resolution:2026-10-20:<codigo>`. Cada movimiento
incluye el esperado, contado, diferencia, saldo previo, clasificacion y evidencia.

## Casos sin ajuste

| Codigo | Diferencia/hallazgo | Estado del analisis |
| --- | ---: | --- |
| 720 | +1 y hallazgo vencido | La hoja 61843 confirma la devolucion completa de 11 unidades. La unidad fisica adicional tiene otro origen aun no demostrado. |
| 730 | +2 | Pendiente revisar el movimiento de vencimiento No. 346. La hoja 39377 no corresponde: esa hoja retiro el codigo 732. |
| 737 | -2 | Posible relacion con el movimiento asignado al 730, pendiente de soporte documental. |
| 736 | Hallazgo, sin diferencia | Fue marcado manualmente como vencido, pero vence el 30/11/2026. Al 20/10/2026 estaba proximo a vencer. Se conserva el hallazgo original y se documenta como error de clasificacion manual. |
| 773 | Hallazgo, sin diferencia | La aplicacion conserva una unidad fisica vencida y cero vendible; el ERP muestra cero. La barrera de despacho funciona, pero falta conciliar la disposicion fisica/ERP. |

## Dictamen tecnico

- **Error de la aplicacion/proceso de importacion:** codigos 765, 766, 789 y
  790. La validacion de duplicados no detecto que compras historicas ya estaban
  incorporadas en el snapshot de existencia cargado posteriormente.
- **Diferencia fisica real sin causa raiz demostrada:** codigos 745, 750 y 771.
  No debe etiquetarse automaticamente como error manual del usuario.
- **Error manual de clasificacion:** codigo 736, porque la fecha aun era vigente.
- **Pendientes documentales:** codigos 720, 730 y 737.
- **Control de seguridad correcto:** el codigo 773 permanece fisico pero no
  vendible, por lo que no puede despacharse como medicamento vigente.

## Validaciones posteriores obligatorias

- Deben existir siete movimientos correctivos y sumar `-46`.
- Los saldos posteriores esperados, antes de nuevos movimientos operativos, son:
  745=3, 750=23, 765=7, 766=8, 771=1, 789=1 y 790=2.
- Las filas originales del conteo deben conservar exactamente sus valores.
- El tablero de diferencias debe dejar como pendientes cuantitativos solamente
  720 (+1), 730 (+2) y 737 (-2).
- No debe existir ninguna clave de resolucion para 720, 730 o 737.

## Resultado de la aplicacion

La conciliacion fue aplicada el 20/10/2026 y supero las validaciones posteriores:

- Se crearon **7 movimientos** por un total de **-46 unidades**.
- Ninguna fila de `inventory_count_session_items` fue actualizada.
- No se creo ningun movimiento para 720, 730 o 737.
- Los siete saldos corregidos quedaron iguales al conteo fisico:

| Codigo | Esperado original | Conteo fisico | Ajuste posterior | Saldo resultante |
| --- | ---: | ---: | ---: | ---: |
| 745 | 4 | 3 | -1 | 3 |
| 750 | 27 | 23 | -4 | 23 |
| 765 | 22 | 7 | -15 | 7 |
| 766 | 23 | 8 | -15 | 8 |
| 771 | 2 | 1 | -1 | 1 |
| 789 | 6 | 1 | -5 | 1 |
| 790 | 7 | 2 | -5 | 2 |

La nueva lista de diferencias cuantitativas pendientes queda limitada a:

- 720: `+1`.
- 730: `+2`.
- 737: `-2`.

Los hallazgos originales permanecen en 720, 736 y 773. Esta permanencia es
intencional: el conteo conserva exactamente lo observado y digitado ese dia; la
interpretacion corregida se documenta en este informe, no se reescribe en la
evidencia original.

## Prevencion recomendada

La importacion de compras debe comparar la fecha/documento de cada compra contra
el corte del snapshot de existencia. Si la compra ya esta contenida en ese corte,
debe advertirse y excluirse, aunque el archivo de compras no haya sido cargado
antes en la aplicacion. Esta mejora se implementara por separado para no mezclar
la correccion de datos con un cambio de comportamiento.
