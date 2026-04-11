#!/bin/bash
# QemuCP - Patch de traducciones para OpenLiteSpeed
# Añade las traducciones OLS al fichero .mo de HestiaCP

HESTIA=/usr/local/hestia
LOCALE_DIR="$HESTIA/web/locale"

# Crear .po temporal con las nuevas cadenas
for LANG in es fr de pt it; do
    PO_FILE="$LOCALE_DIR/$LANG/LC_MESSAGES/hestiacp.po"
    MO_FILE="$LOCALE_DIR/$LANG/LC_MESSAGES/hestiacp.mo"

    [[ -f "$MO_FILE" ]] || continue

    # Extraer .po desde .mo si existe
    if command -v msgunfmt &>/dev/null; then
        msgunfmt -o "$PO_FILE" "$MO_FILE" 2>/dev/null || continue
    else
        continue
    fi

    # Añadir traducciones segun idioma
    case $LANG in
        es)
            cat >> "$PO_FILE" << 'ESPO'
msgid "Web Engine"
msgstr "Motor Web"
msgid "OpenLiteSpeed provides native LSCache for 10x faster WordPress and PrestaShop"
msgstr "OpenLiteSpeed proporciona LSCache nativo para WordPress y PrestaShop hasta 10x más rápido"
ESPO
            ;;
        fr)
            cat >> "$PO_FILE" << 'FRPO'
msgid "Web Engine"
msgstr "Moteur Web"
msgid "OpenLiteSpeed provides native LSCache for 10x faster WordPress and PrestaShop"
msgstr "OpenLiteSpeed fournit LSCache natif pour WordPress et PrestaShop jusqu'à 10x plus rapide"
FRPO
            ;;
        de)
            cat >> "$PO_FILE" << 'DOPO'
msgid "Web Engine"
msgstr "Web-Engine"
msgid "OpenLiteSpeed provides native LSCache for 10x faster WordPress and PrestaShop"
msgstr "OpenLiteSpeed bietet nativen LSCache für bis zu 10x schnelleres WordPress und PrestaShop"
DOPO
            ;;
    esac

    # Recompilar .mo
    if command -v msgfmt &>/dev/null; then
        msgfmt -o "$MO_FILE" "$PO_FILE" 2>/dev/null && \
            echo "Traduccion $LANG actualizada" || \
            echo "Error compilando $LANG"
        rm -f "$PO_FILE"
    fi
done
