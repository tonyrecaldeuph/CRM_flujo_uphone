# ADR-003 — Cifrado en reposo de la base de datos SQLite

- **Estado:** Propuesto (pendiente de decisión del Holding + Legal)
- **Fecha:** 2026-06-03
- **Decisores:** P.O., Empresa de desarrollo, Holding (Seguridad/Legal)
- **Relacionado:** [`docs/KNOWN-ISSUES.md`](../../docs/KNOWN-ISSUES.md) (SEC-1), ADR-004

---

## Contexto

La base de datos es un archivo SQLite (`better-sqlite3`) en disco en la VM (`F:\cobranza\data\terminal.db`), legible en claro por cualquier proceso/usuario con acceso al sistema de archivos. Un escaneo de seguridad lo marcó como "datos sin cifrar en reposo". La BD contiene **datos personales** (cédulas, teléfonos, deudas) → relevante para la LOPDP (Ecuador).

**Matiz crítico del modelo de amenaza:** el cifrado en reposo de SQLite protege contra **exfiltración del archivo o backup** y **robo de disco offline**, pero **NO** contra un atacante con **acceso a la VM en ejecución**, porque la aplicación necesita la clave de descifrado en esa misma VM (quien entra puede leerla).

## Decisión

Adoptar un enfoque **por capas**, no una sola medida:

1. **Control de acceso a la VM** (lo que realmente mitiga el acceso a la VM): restringir RDP por NSG/IP, MFA, mínimo de cuentas admin, least-privilege. *Prioridad alta, independiente del cifrado.*
2. **Cifrar backups** que salen de la VM (Azure Blob).
3. **Cifrado a nivel app** con `better-sqlite3-multiple-ciphers` (drop-in de better-sqlite3, SQLCipher/AES-256), con la **clave en Azure Key Vault** obtenida vía Managed Identity al arranque — **nunca** en `.env` junto al `.db`.
4. Confirmar **Azure SSE** (cifrado de disco administrado por plataforma, suele estar activo por defecto) y evaluar **Azure Disk Encryption (BitLocker)** para robo offline.

## Consecuencias

**Positivas:** protege exfiltración de archivo/backup; cumple mejor con LOPDP; clave gestionada fuera del disco.
**Negativas / costo:** cambio de módulo nativo (recompilar) + **migración de la BD existente** (claro→cifrada vía `PRAGMA rekey`) con ventana y backup; dependencia de Key Vault; el cifrado app **no** sustituye el control de acceso a la VM.

## Alternativas consideradas

- **Solo disk encryption (BitLocker/SSE):** cubre robo de disco, no acceso a VM viva ni exfiltración con la VM montada. Insuficiente por sí solo.
- **SQLCipher compilando better-sqlite3:** frágil en Windows; se prefiere el fork `multiple-ciphers`.
- **No cifrar (statu quo):** descartado por el hallazgo de seguridad y la PII.

## Referencias
- `better-sqlite3-multiple-ciphers`, Azure Key Vault + Managed Identity, LOPDP (Ecuador).
