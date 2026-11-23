# expense-tracker-data-model

Modelo de datos relacional y capa de consultas para una aplicación personal de control de gastos con tarjeta, multimoneda (GTQ/USD), detección de duplicados, liquidación de gastos y registro de dinero prestado.

## Qué es este repositorio

Este repositorio es un **extracto de portafolio**. Contiene únicamente la capa de datos (esquema, datos sintéticos y consultas de reporte) de un proyecto personal privado. No es la aplicación original y no incluye su interfaz, su motor de OCR, su persistencia en un servicio NoSQL gestionado ni sus módulos de ahorros, gastos fijos y financiamiento por cuotas.

Todo el contenido es verificable, reproducible y **estático**:

- **No hay datos personales.** Ni nombres, ni tarjetas reales, ni comercios reales, ni montos tomados de la aplicación original. Los datos de `schema/02-seed.sql` son inventados: "Comercio Ejemplo", "Supermercado Demo", "Tarjeta Demo A".
- **No hay código de aplicación.** El repositorio es SQL portable más un verificador en Python que usa solo la biblioteca estándar.
- **No hay configuración de terceros.** Cero claves, cero credenciales, cero referencias a servicios externos, cero imágenes.

La lógica de negocio se expresa en la base de datos: claves foráneas, restricciones `CHECK`, una restricción `UNIQUE` para duplicados y una vista de integridad. No hay una capa de aplicación que "recuerde" las reglas.

## Modelo

El diagrama completo está en [`diagram/er.mmd`](diagram/er.mmd) (Mermaid `erDiagram`).

| Tabla | Rol en el dominio |
| --- | --- |
| `currency` | Monedas admitidas. El conjunto está cerrado a `GTQ` y `USD` porque la aplicación original hard-codeaba ambas en la interfaz y en la firma de duplicados. |
| `card` | Perfil de tarjeta: etiqueta y últimos dígitos. |
| `capture_batch` | Sesión de captura: escaneo OCR, carga manual o notificación bancaria ingerida. |
| `payment_batch` | Liquidación: el momento en que un conjunto de gastos pasa a "pagado". El total no se almacena, se deriva de los gastos enlazados. |
| `expense` | Gasto con tarjeta: moneda, tarjeta, lote de captura, descripción, monto, fecha de consumo y lote de liquidación. |
| `detected_duplicate` | Duplicado detectado: enlaza la copia con el gasto original y guarda el estado de la alerta. |
| `loan` | Dinero prestado a un tercero, con moneda, descripción, monto y fecha. |
| `loan_payment_batch` | Liquidación de préstamos. |

Decisiones estructurales:

- **Claves primarias enteras explícitas.** Ninguna tabla usa `AUTOINCREMENT`, `SERIAL` ni secuencias: el escritor de la fila decide el identificador. Esto mantiene el esquema idéntico en SQLite y PostgreSQL y hace que los datos sintéticos sean reproducibles byte a byte.
- **Dinero en centavos (`amount_cents`, entero).** La aplicación original guardaba montos como números de JavaScript y los normalizaba con `toFixed(2)` cada vez que comparaba. Almacenar unidades menores elimina el problema de raíz: dos montos iguales son iguales como enteros, y `CHECK (amount_cents > 0)` codifica que los abonos y reembolsos negativos no son gastos (la captura original los descartaba).
- **La tarjeta no participa en la identidad del gasto.** Un gasto no tiene una clave natural propia; lo que lo identifica para el negocio es su firma de duplicado (ver más abajo). La tarjeta es un atributo, y `card_id` admite `NULL` para los gastos externos o en efectivo, que en la aplicación original se registraban con el valor ficticio `GASTO_EXTERNO`.
- **Fechas como texto ISO 8601 (`YYYY-MM-DD`).** Es el tipo `TEXT`/`DATE` estándar, se ordena lexicográficamente y evita conversiones dependientes del motor.
- **Índices orientados a consultas reales.** `(currency_id, spent_on)` para el gasto mensual y el historial, `(card_id)` para el desglose por tarjeta, `(payment_batch_id)` para el detalle de liquidaciones, `(capture_batch_id, duplicate_signature)` como restricción, `(currency_id, lent_on)` para préstamos pendientes y `(currency_id, paid_on)` para listar lotes.

## Regla de detección de duplicados

En la aplicación original la regla era explícita: dos gastos son duplicados si coinciden en **moneda + monto + descripción**, con la descripción normalizada (mayúsculas, sin espacios, guiones ni guiones bajos) y el monto redondeado a dos decimales. La tarjeta y la persona se ignoraban a propósito, para detectar el mismo consumo capturado dos veces aunque se hubiera asignado a otra tarjeta. La detección se ejecutaba contra *todos* los gastos existentes y el resultado era una alerta, no un rechazo: amarilla si la copia original seguía pendiente de pago, roja si ya estaba liquidada. La decisión final era humana.

En este modelo la regla vive en tres lugares de la base de datos:

1. **`expense.duplicate_signature`** es una columna generada (`STORED`):

   ```sql
   CAST(currency_id AS TEXT) || '|' || CAST(amount_cents AS TEXT) || '|' ||
   REPLACE(REPLACE(REPLACE(UPPER(TRIM(description)), ' ', ''), '-', ''), '_', '')
   ```

   Es la firma del origen, calculada por el motor y siempre coherente con las columnas de las que depende. No hay forma de insertar un gasto con una firma que no corresponda a sus datos.

2. **`UNIQUE (capture_batch_id, duplicate_signature)`**: un mismo lote de captura no puede producir dos veces la misma firma. Un estado de cuenta escaneado dos veces se rechaza en el momento del `INSERT`. Esta es la parte que la base de datos **impone**.

3. **`detected_duplicate`** con dos claves foráneas compuestas sobre `(expense_id, duplicate_signature)` y `(original_expense_id, duplicate_signature)`, más `CHECK (expense_id <> original_expense_id)` y `UNIQUE` implícito en `expense_id`. Una declaración de duplicado solo es válida si las dos filas enlazadas existen **y comparten la firma**. Un duplicado inventado, mal enlazado o autorreferente es rechazado por el motor.

La vista **`v_undeclared_duplicate`** cierra el círculo: lista todo gasto que repite una firma anterior sin estar declarado en `detected_duplicate`. El verificador exige que esté vacía para los datos sintéticos. Es también la consulta recomendada después de cualquier importación masiva.

### Diferencia con la regla del origen y su costo

La regla del origen **no distingue** un duplicado real (el mismo consumo capturado dos veces) de una repetición legítima (dos cafés del mismo precio el mismo día, o el mismo supermercado con el mismo monto otro mes). El origen resolvía esa ambigüedad con una alerta y una decisión humana. Una restricción `UNIQUE` global sobre la firma habría rechazado compras legítimas, así que el modelo la aplica donde la ambigüedad no existe: **dentro de un mismo lote de captura**. Fuera del lote, la repetición se registra en `detected_duplicate` y la base de datos garantiza que la declaración sea consistente con la firma, pero no la prohíbe.

Consecuencia práctica: el motor no puede impedir por sí solo que se inserte dos veces el mismo gasto en lotes distintos. Lo que sí garantiza es que ese caso quede visible (la vista de integridad) y que la alerta registrada sea verificable. Es un intercambio deliberado entre integridad y fidelidad al dominio: se rechaza lo que es inequívocamente un error y se marca lo que requiere criterio humano.

## Dialecto SQL

El SQL es portable y se ejecuta sin cambios en SQLite 3.x (a través del módulo `sqlite3` de Python) y en PostgreSQL 12 o superior. La afirmación se sostiene en estas decisiones:

- Sin `AUTOINCREMENT`, sin `SERIAL`, sin `ENUM`, sin `PRAGMA` en el DDL, sin comandos de cliente (`\d`, `\copy`), sin funciones de un solo motor (`printf`, `julianday`, `datetime`, `strftime`).
- Columnas generadas con la sintaxis estándar `GENERATED ALWAYS AS (...) STORED`, disponible en PostgreSQL 12+ y SQLite 3.31+. El verificador se ejecutó con la versión de SQLite incluida en Python 3.12.
- Funciones usadas: `UPPER`, `TRIM`, `REPLACE`, `CAST`, `COALESCE`, `SUM`, `COUNT`, `ROUND`, `SUBSTR`, `LAG` y `SUM ... OVER`. Todas existen con la misma semántica en ambos motores.
- La integridad referencial de SQLite está desactivada por defecto; `verify.py` ejecuta `PRAGMA foreign_keys = ON` en su conexión. PostgreSQL la aplica siempre. Ese `PRAGMA` es del driver, no del esquema, y por eso no aparece en `schema/01-ddl.sql`.

La única diferencia conocida es de representación, no de comportamiento: en PostgreSQL las divisiones de `amount_cents / 100.0` producen `numeric` y en SQLite `real`, ambos redondeados con `ROUND(..., 2)` en las consultas.

Alcance de la verificación: la ejecución registrada en este repositorio es contra SQLite. La compatibilidad con PostgreSQL se sostiene en la sintaxis empleada (nada exclusivo de un motor) y no en una prueba ejecutada aquí; no se incluye una instancia de PostgreSQL en la verificación.

## Cómo verificar

Requisitos: Python 3.8 o superior. Nada más, sin dependencias externas.

```bash
cd expense-tracker-data-model
python verify.py
```

El verificador crea una base SQLite temporal en el directorio temporal del sistema, aplica `schema/01-ddl.sql` y `schema/02-seed.sql`, ejecuta las comprobaciones de reglas, corre **todas** las consultas de `queries/`, imprime un resumen compacto por consulta (cantidad de filas y primeras filas), borra el directorio temporal y termina con código distinto de cero si algo falla.

Comprobaciones de reglas incluidas (todas contra el motor, ninguna simulada en Python):

| Comprobación | Resultado esperado |
| --- | --- |
| Firma repetida dentro del mismo lote de captura | rechazada |
| Misma firma en otro lote | aceptada |
| Mismo monto con un centavo de diferencia | aceptada |
| Gasto con tarjeta inexistente | rechazado |
| Gasto con moneda inexistente | rechazado |
| Monto igual a cero | rechazado |
| Moneda fuera del conjunto admitido (`EUR`) | rechazada |
| Dígitos de tarjeta fuera de rango | rechazados |
| Duplicado declarado con firma distinta | rechazado |
| Gasto declarado como su propio duplicado | rechazado |
| Filas en `v_undeclared_duplicate` | cero |

Salida observada en la última ejecución (código de salida 0):

```text
Schema applied: 01-ddl.sql
Seed applied: 02-seed.sql
Seed rows: 2 currency, 18 expense
Rule checks
  [ok] duplicate signature inside one capture batch is rejected: rejected (expected rejected)
  [ok] same signature in a different capture batch is allowed: accepted (expected accepted)
  [ok] different amount breaks the signature (legitimate repeat): accepted (expected accepted)
  ...
Report queries
  [ok] 01_monthly_spend_by_currency.sql: 6 row(s)
  [ok] 02_spend_per_card.sql: 4 row(s)
  [ok] 03_top_merchants.sql: 7 row(s)
  [ok] 04_detected_duplicates.sql: 2 row(s)
  [ok] 05_outstanding_loans.sql: 2 row(s)
  [ok] 06_month_over_month.sql: 6 row(s)

RESULT: OK
```

## Catálogo de consultas

| Archivo | Pregunta de negocio | Técnica destacada |
| --- | --- | --- |
| `queries/01_monthly_spend_by_currency.sql` | ¿Cuánto se gasta por mes y por moneda, y cuánto sigue pendiente de pago? | Agregación con `SUM(CASE ...)` para separar liquidado y pendiente |
| `queries/02_spend_per_card.sql` | ¿Qué tarjeta concentra el gasto y cuánto le queda pendiente? | `LEFT JOIN` para incluir gastos externos sin tarjeta |
| `queries/03_top_merchants.sql` | ¿Dónde se va el dinero? | Agrupación por la descripción normalizada de la firma |
| `queries/04_detected_duplicates.sql` | ¿Qué capturas se marcaron como duplicadas y qué tan crítica es cada una? | Doble unión sobre `expense` y estado `pending`/`paid` |
| `queries/05_outstanding_loans.sql` | ¿Cuánto dinero prestado sigue sin devolver, por moneda? | `SUM(...) OVER (PARTITION BY ...)` para el total por moneda |
| `queries/06_month_over_month.sql` | ¿Este mes es más caro que el anterior, por moneda? | CTE y `LAG(...) OVER (PARTITION BY ... ORDER BY ...)` con variación porcentual |

## Alcance del extracto y decisiones a confirmar

Lo que quedó fuera, por no pertenecer a la capa de datos o por contener información privada:

- Interfaz, estilos, exportación a imagen y a `.xlsx`, notificaciones del navegador y servicio PWA.
- Motor de OCR con Tesseract y su heurística de limpieza de texto.
- Persistencia en un servicio NoSQL gestionado, sus reglas de acceso y la configuración del proyecto en la nube.
- Lector de notificaciones Android.
- Módulos de ahorros, gastos fijos y financiamiento por cuotas (bolsas, visacuotas, periodos mensuales), que en el proyecto original son colecciones independientes con su propio ciclo de vida.

Decisiones de diseño que conviene revisar con el autor del proyecto original:

1. **No existe el concepto de categoría.** La aplicación original no clasificaba gastos: el único agrupamiento disponible era la descripción libre y la tarjeta. No se inventó una tabla `category`; si se quisiera, bastaría una tabla de búsqueda y una clave foránea opcional en `expense`.
2. **El lote de captura es una interpretación.** El flujo OCR generaba una tabla temporal de filas y las guardaba en orden, pero nunca persistía la sesión. `capture_batch` modela explícitamente lo que la interfaz ya implicaba y es lo que hace posible distinguir un error de captura de una repetición legítima.
3. **La firma usa `currency_id` en lugar del código de moneda.** Una columna generada no puede leer otra tabla, así que la firma usa el identificador de la moneda. Es equivalente porque `currency.code` es único, pero la firma resultante (`1|42500|SUPERMERCADODEMO`) es menos legible que la del origen (`1|425.00|SUPERMERCADO DEMO`).
4. **La normalización cubre espacio, guion y guion bajo, no todo `\s`.** El origen usaba la expresión regular `/[\s\-_]/g`, que también elimina tabuladores y saltos de línea. `UPPER`/`REPLACE` estándar no puede expresar `\s` de forma portable, así que tabuladores y saltos de línea no se eliminan. En la práctica el texto proviene de una línea de estado de cuenta.
5. **`UPPER` en SQLite solo transforma caracteres ASCII.** Para descripciones con acentos, la normalización no convierte `é` en `É`. Ambos lados de la comparación usan la misma función, así que la detección sigue siendo consistente; cambia únicamente la forma exacta de la firma respecto del origen.
6. **Los últimos dígitos de la tarjeta son un entero (0..9999).** El origen los guardaba como texto de 1 a 4 caracteres. El entero hace imposible un valor no numérico, pero no puede representar un cero inicial (`0123` se guardaría como `123`).
7. **`card.label` es único.** El origen usaba el nombre como clave de los gastos, así que dos tarjetas con el mismo nombre se habrían mezclado; aquí el esquema lo impide.
8. **La firma antigua con persona fue descartada.** El código original todavía escribía una firma heredada `persona_moneda_monto_descripcion` y la aceptaba al comparar, por retrocompatibilidad con registros viejos. Aquí no hay datos heredados: solo existe la firma documentada (moneda, monto, descripción) y la tarjeta nunca participa.
9. **Un gasto pagado se liquida por completo.** Igual que el origen, no se modelan abonos parciales: `payment_batch_id` nulo significa pendiente y no nulo significa liquidado. Un pago parcial requeriría una tabla de aplicación de pagos.
10. **`detected_duplicate.status` no se puede derivar con un `CHECK`.** El origen decidía entre alerta amarilla y roja según si el original ya estaba pagado. Esa regla cruza dos filas y una restricción `CHECK` no puede expresarla; el estado se guarda y la vista de integridad ayuda a mantenerlo coherente. La misma limitación aplica a que el lote de pago y el gasto compartan moneda.
11. **No se modela al deudor de un préstamo.** El proyecto original nunca guardó a quién se le prestó: solo una descripción libre. No se añadió ese dato para no inventar dominio ni introducir información personal.

## Privacidad

Los datos de `schema/02-seed.sql` son sintéticos en su totalidad. No se copió ninguna fila, monto, nombre, tarjeta, comercio ni captura del proyecto original. Las palabras clave del proyecto privado, sus clientes y sus servicios no aparecen en este repositorio.
