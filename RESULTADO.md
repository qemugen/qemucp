# Resultado de la prueba completa de QemuCP

- Rama: `release`
- Commit: `66800e85a` — Exim: message_linelength_limit ampliado (Exim 4.95+ devolvia correos de Outlook/formularios con 'lines too long for transport'); reparacion al relanzar el instalador
- Fecha: 2026-10-16 10:22 UTC
- Ejecucion: https://github.com/qemugen/qemucp/actions/runs/38883584921

| Fase | Resultado |
|---|---|
| Instalacion desde cero | OK |
| Pruebas QemuCP | OK — 34 correctas, 0 fallidas |
| Relanzar el instalador | OK |
| Pruebas tras relanzar | OK — 34 correctas, 0 fallidas |
| Actualizacion + hook | OK |
| Actualizar (--actualizar) | OK |
| Pruebas tras actualizar | OK — 34 correctas, 0 fallidas |
| Migrador de cPanel | OK — 41 correctas, 0 fallidas |
| Bateria de HestiaCP | OK — 255 correctas, 0 fallidas |

