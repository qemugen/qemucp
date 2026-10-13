#!/usr/bin/env python3
# =============================================================================
#  QemuCP - textos propios en espanol para usuarios no tecnicos
#
#  Anade o corrige entradas en web/locale/es/LC_MESSAGES/hestiacp.mo (el
#  repo solo trae el .mo compilado, no el .po). Idempotente.
#
#  Hay que relanzarlo despues de sincronizar las traducciones de upstream
#  (git merge de una version nueva de HestiaCP): el .mo de upstream no trae
#  estos textos. test/qemucp.bats comprueba que estan.
#
#  Uso:  python3 install/qemucp-textos.py [ruta/al/hestiacp.mo]
# =============================================================================

import os
import struct
import sys

TEXTOS = {
    # Selector de version de PHP (antes "Plantilla Backend")
    "PHP Version": "Versión de PHP",
    "Server default": "Por defecto del servidor",
    # WP-TOOL (gestor de WordPress: web/list/wp, web/edit/wp)
    "WordPress Manager": "Gestor de WordPress",
    "APPLICATIONS": "APLICACIONES",
    "Applications": "Aplicaciones",
    "WordPress and more": "Instalar y gestionar",
    "Install an application": "Instalar una aplicación",
    "Install": "Instalar",
    "Install in the website": "Instalar en la web",
    "To install an application you first need a website.":
        "Para instalar una aplicación primero necesitas una web.",
    "Needs a PHP version that is not installed.": "Necesita una versión de PHP que no está instalada.",
    "Your installed applications": "Tus aplicaciones instaladas",
    "You have no WordPress installed yet. Install it from the list above.":
        "Todavía no tienes ningún WordPress. Puedes instalarlo desde la lista de arriba.",
    "Website": "Web",
    "Active": "Activa",
    "In maintenance": "En mantenimiento",
    "Open WordPress": "Entrar en WordPress",
    "Update all": "Actualizar todo",
    "Make backup": "Hacer copia de seguridad",
    "Clear cache": "Vaciar caché",
    "Maintenance mode": "Modo mantenimiento",
    "End maintenance": "Quitar mantenimiento",
    "Update WordPress, plugins and themes of %s? Make a backup first if you are not sure.":
        "¿Actualizar WordPress, plugins y temas de %s? Si no estás seguro, haz antes una copia de seguridad.",
    "Make a backup of %s (files and database)?":
        "¿Hacer una copia de seguridad de %s (archivos y base de datos)?",
    "Make %s visible to visitors again?": "¿Volver a mostrar %s a los visitantes?",
    "Show a maintenance notice to the visitors of %s?":
        "¿Mostrar un aviso de mantenimiento a los visitantes de %s?",
    "No WordPress has been found in your websites yet.":
        "Todavía no hay ningún WordPress en tus webs.",
    "Install WordPress": "Instalar WordPress",
    "Choose the website where you want to install it:": "Elige la web donde quieres instalarlo:",
    "Install WordPress in %s": "Instalar WordPress en %s",
    "WordPress, plugins and themes updated.": "WordPress, plugins y temas actualizados.",
    "Maintenance mode enabled.": "Modo mantenimiento activado.",
    "Maintenance mode disabled.": "Modo mantenimiento desactivado: la web vuelve a verse.",
    "Cache cleared.": "Caché vaciada.",
    "Backup created in %s": "Copia de seguridad creada en %s",
    "The action could not be completed.": "No se ha podido completar la acción.",
    # Aviso al entrar en la cuenta de un usuario (panel.php)
    "You are managing the account of %s": "Estás gestionando la cuenta de %s",
    "Back to your account": "Volver a tu cuenta",
    # Lista de webs: subdominios agrupados bajo su dominio
    "Subdomain": "Subdominio",
    "1 subdomain": "1 subdominio",
    "%d subdomains": "%d subdominios",
    "Also answers to": "También responde a",
    # Performance Dashboard (web/list/performance)
    "Performance": "Rendimiento",
    "Server Performance": "Rendimiento del servidor",
    "Updated every 10 seconds.": "Se actualiza cada 10 segundos.",
    "The data could not be loaded.": "No se han podido cargar los datos.",
    "Processor": "Procesador",
    "cores": "núcleos",
    "Load average": "Carga media",
    "Cache (Redis)": "Caché (Redis)",
    "Hit rate": "Aciertos",
    "Connections": "Conexiones",
    "Running": "Funcionando",
    "Stopped": "Parado",
}

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MO = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    RAIZ, "web", "locale", "es", "LC_MESSAGES", "hestiacp.mo")


def leer(ruta):
    datos = open(ruta, "rb").read()
    magia = struct.unpack("<I", datos[:4])[0]
    fmt = "<" if magia == 0x950412DE else ">"
    _, n, o_orig, o_trad = struct.unpack(fmt + "4I", datos[4:20])
    entradas = []
    for i in range(n):
        lo, po = struct.unpack(fmt + "2I", datos[o_orig + i * 8:o_orig + i * 8 + 8])
        lt, pt = struct.unpack(fmt + "2I", datos[o_trad + i * 8:o_trad + i * 8 + 8])
        entradas.append((datos[po:po + lo], datos[pt:pt + lt]))
    return entradas


def escribir(ruta, entradas):
    # Ordenadas por msgid (gettext busca por biseccion) y sin tabla hash
    entradas = sorted(entradas, key=lambda e: e[0])
    n = len(entradas)
    o_orig = 28
    o_trad = o_orig + n * 8
    pos = o_trad + n * 8
    tabla_o, tabla_t, cuerpo = b"", b"", b""
    for orig, _ in entradas:
        tabla_o += struct.pack("<2I", len(orig), pos + len(cuerpo))
        cuerpo += orig + b"\0"
    for _, trad in entradas:
        tabla_t += struct.pack("<2I", len(trad), pos + len(cuerpo))
        cuerpo += trad + b"\0"
    cab = struct.pack("<7I", 0x950412DE, 0, n, o_orig, o_trad, 0, pos)
    tmp = ruta + ".tmp"
    with open(tmp, "wb") as f:
        f.write(cab + tabla_o + tabla_t + cuerpo)
    os.replace(tmp, ruta)


def main():
    entradas = dict(leer(MO))
    cambios = 0
    for orig, trad in TEXTOS.items():
        o, t = orig.encode("utf-8"), trad.encode("utf-8")
        if entradas.get(o) != t:
            entradas[o] = t
            cambios += 1
            print("  + %s -> %s" % (orig, trad))
    if not cambios:
        print("Textos de QemuCP ya presentes en %s" % MO)
        return
    escribir(MO, list(entradas.items()))
    # Comprobacion: gettext tiene que poder leerlo
    import gettext
    with open(MO, "rb") as f:
        t = gettext.GNUTranslations(f)
    for orig, trad in TEXTOS.items():
        assert t.gettext(orig) == trad, orig
    print("%d textos actualizados en %s" % (cambios, MO))


if __name__ == "__main__":
    main()
