# Botiquín CCM

Aplicación web interna para la operación del Botiquín CCM: catálogo farmacéutico,
inventario por producto y lote, despacho con FEFO, validación de Caja,
auditoría física, devoluciones a proveedor, dispositivos serializados,
importaciones y análisis comercial.

## Documentación técnica

- [Índice de documentación](docs/README.md)
- [Arquitectura técnica](docs/arquitectura-tecnica.md)
- [Modelo de datos](docs/modelo-datos.md)
- [Modelo entidad-relación](docs/modelo-entidad-relacion.md)
- [Matriz de pantallas, roles y RPC](docs/matriz-pantallas-rpc.md)

La aplicación se publica como sitio estático en GitHub Pages y usa Supabase
(PostgreSQL + PostgREST) como backend. La lógica que modifica datos reside en
funciones RPC; el navegador no es la autoridad de seguridad ni de inventario.
