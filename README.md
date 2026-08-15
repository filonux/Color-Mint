<a href="assets/icon.png"><img src="assets/icon.png" alt="Icono de Color Mint" width="120"></a>

# Color Mint

Personalización estética de Linux Mint Cinnamon en una sola ventana: temas, panel, escritorio, terminal y fuentes — con copia de seguridad automática antes de cada cambio.

[![Bash 4+](https://img.shields.io/badge/bash-%3E%3D4.0-4EAA25?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/) [![Linux Mint 22.3 Cinnamon](https://img.shields.io/badge/Linux%20Mint-22.3%20Cinnamon-87CF3E?logo=linuxmint&logoColor=white)](https://linuxmint.com/) [![Licencia GPLv3](https://img.shields.io/badge/licencia-GPLv3-blue)](LICENSE)

> 🇪🇸 Este proyecto está documentado y funciona íntegramente en español. Si te interesa una versión en inglés, hay más detalles al final, en [Sobre el idioma](#sobre-el-idioma).

---

## El problema que resuelve

Cinnamon reparte su apariencia entre el panel de Ajustes, `dconf-editor` y comandos sueltos de `gsettings` — y hay cosas que ni siquiera están ahí: color de acento del panel, paletas de color para el terminal, un acento que se note en todas las apps GTK a la vez. Encima, las claves que hay que tocar viven bajo esquemas poco obvios (`org.cinnamon.desktop.interface` para casi todo, pero `org.gnome.desktop.interface` para la fuente monoespaciada, por poner un ejemplo real) que hay que conocer de memoria o adivinar.

Color Mint junta todo eso —temas, panel, escritorio, terminal y fuentes— en una sola ventana, o en una sola línea de comandos si prefieres la terminal. Ya sabe qué esquema toca en cada caso, y guarda una copia de seguridad antes de aplicar cualquier cambio.


<img width="945" height="762" alt="color-mint-menu" src="https://github.com/user-attachments/assets/f4afd370-58fc-416f-9355-081fc0711d98" />
<img width="943" height="768" alt="2 mint-colorr-panel" src="https://github.com/user-attachments/assets/0206a86b-1d82-4ca5-981f-cb3875236ead" />
<img width="946" height="760" alt="3 mint-color-escritorio" src="https://github.com/user-attachments/assets/01e96f4c-631f-4cb4-b1b8-d205cba1aacf" />
<img width="944" height="756" alt="4 mint-color-avanzado" src="https://github.com/user-attachments/assets/62e5b70d-cb28-46c2-bcbc-0b872f527329" />
<img width="936" height="768" alt="5 mint-color-terminal" src="https://github.com/user-attachments/assets/0c8ae2b0-0023-41e3-8914-ddcd27023351" />
<img width="945" height="764" alt="6 mint-color-fuentes" src="https://github.com/user-attachments/assets/8301519c-63f9-4b43-adf9-bf5982a01e3e" />
<img width="942" height="759" alt="7 mint-color-perfiles" src="https://github.com/user-attachments/assets/0dd41a43-38fb-4bca-95ae-c44eb0841d4f" />


## Funciones

Siete bloques, tanto en la interfaz gráfica como en la terminal:

- **🎨 Temas** — tema GTK, iconos, cursor (con su tamaño) y tema de Cinnamon. Un camino rápido con los colores oficiales del paquete Mint-Y, o pieza por pieza si prefieres mezclar temas de terceros. También importa temas descargados en `.zip`, `.tar.gz`, `.tar.xz` o `.tar.bz2`, listos para aplicar.
- **🖥️ Panel** — color de acento, fondo y texto del panel, fondo y texto de los menús, fondo y texto de los tooltips, opacidad y alto. Incluye un acento GTK global que tiñe cualquier app GTK3/GTK4 instalada, no solo el panel.
- **🪟 Escritorio** — posición del panel, botones de ventana (7 presets o una cadena a medida), efectos al abrir/cerrar ventanas y menús, número de espacios de trabajo, iconos del escritorio y color de fondo.
- **🧩 Avanzado** — las cuatro esquinas activas (hot corners) y los botones de ventana con cadena personalizada, separado de «Escritorio» para no llenarla de campos.
- **⌨️ Terminal** — nueve paletas de color listas para el perfil por defecto de gnome-terminal, o colores de fondo/texto a medida.
- **🔤 Fuentes** — fuente de la interfaz, fuente monoespaciada, antialiasing + hinting y escala del texto.
- **💾 Perfiles** — guarda el estado actual como preset con nombre, carga uno guardado, o restaura cualquier copia de seguridad automática anterior.

Cada una de estas acciones tiene su comando de terminal equivalente — la referencia completa está más abajo, en [Comandos](#comandos).

## La ventaja principal

No es ningún ajuste concreto: es que no hace falta saber nada de esto de antemano.

Cambiar el acento del panel, aplicar una paleta al terminal, o conseguir que un color se note en todas tus apps GTK normalmente implica abrir `dconf-editor`, adivinar el esquema correcto (que cambia según el ajuste, como se explica arriba) y, en el caso del acento, editar a mano el CSS del tema activo. Color Mint ya sabe todo eso — los comentarios técnicos al principio del script documentan, esquema por esquema, cómo se averiguó cada uno, por si te sirven de referencia el día que quieras tocar algo que se sale de aquí.

Antes de aplicar nada, hace automáticamente una copia de seguridad —dconf, temas y fuentes— por cada «Aplicar» que pulses. Así puedes ir probando las siete pestañas sin miedo a dejar el escritorio peor de como estaba: si algo no convence, la pestaña «Perfiles» lo revierte en un clic.

Un par de cosas más que no vienen en el panel de Ajustes de Mint:

- El acento de color no se limita al paquete oficial Mint-Y: funciona sobre cualquier tema de Cinnamon que tengas instalado, detectando su color dominante y sustituyéndolo por el que elijas.
- Ese mismo acento se puede aplicar de forma global a todas las apps GTK3/GTK4, no solo al panel.
- Cada acción de la interfaz gráfica tiene un comando de terminal equivalente, así que todo esto se puede automatizar. Un preset guardado es un archivo de texto plano que se puede versionar, copiar a otra máquina o editar a mano.
- Es un único archivo `.sh` —antes vivía repartido en `gui/`, `lib/` y `presets/`— sin más dependencia real que `yad`, y esa solo hace falta para la interfaz gráfica.

## Instalación

Clonar y ejecutar; no hay ningún paso de instalación aparte:

```bash
git clone https://github.com/filonux/Color-Mint.git
cd color-mint/script
chmod +x color-mint.sh
./color-mint.sh
```

También funciona con `bash color-mint.sh`, sin darle antes permisos de ejecución (el propio script se los añade él solo si puede), o descargando únicamente `script/color-mint.sh` y abriéndolo con doble clic desde el gestor de archivos.

**Dependencias.** En una instalación de fábrica de Mint 22.3 Cinnamon, `dconf`, `gsettings` y `gdbus` ya están instalados. Lo único que suele faltar es `yad` —necesario solo para la interfaz gráfica—; si no lo encuentra, Color Mint te avisa y se ofrece a instalarlo con `apt`, pidiendo tu confirmación antes. Si prefieres adelantarte:

```bash
sudo apt install yad dconf-cli libglib2.0-bin
```

Si solo vas a usar la terminal, es probable que no necesites instalar nada.

Color Mint no pide `sudo` para hacer su trabajo, ni instala nada por su cuenta salvo que se lo pidas explícitamente al faltar una dependencia. Todo lo que guarda —copias de seguridad, presets, logs y el CSS de su propia interfaz— vive en `~/.local/share/color-mint`.

## Uso

### Interfaz gráfica

```bash
./color-mint.sh
# o, es lo mismo:
./color-mint.sh gui
```

Abre una ventana con las siete pestañas descritas en [Funciones](#funciones). Cada una se aplica por separado con su propio botón «Aplicar…»: no hay un botón de guardar al final, cada pestaña confirma sus propios cambios al momento (y hace su propia copia de seguridad justo antes). Al terminar aparece una notificación de escritorio y un diálogo con el detalle real de lo aplicado, marcando con ⚠ cualquier ajuste que fallara en vez de callarlo.

La mayoría de los cambios se ven al instante: Color Mint reinicia el proceso de Cinnamon (no la sesión) después de cada aplicación. La excepción es el tamaño del cursor, que a veces no se refresca en caliente —es una limitación conocida de `cinnamon-settings-daemon`, no del script—; cerrar sesión y volver a entrar siempre lo aplica.

### Terminal

Un comando por ajuste, sin abrir ninguna ventana — cómodo para automatizar o para replicar la misma configuración en varias máquinas:

```bash
./color-mint.sh theme mint-y-color Blue oscuro
./color-mint.sh panel accent "#88C0D0"
./color-mint.sh terminal apply_palette nord
./color-mint.sh preset save mi-setup
```

`./color-mint.sh --help` imprime la referencia completa, agrupada igual que la siguiente sección.

## Comandos

Sintaxis general: `./color-mint.sh <categoría> <acción> [argumentos]`. Los colores siempre van en formato `#RRGGBB`.

### 🎨 Temas

| Comando | Qué hace |
| --- | --- |
| `theme mint-y-color <color> <claro\|oscuro>` | Forma rápida: aplica un color oficial del paquete Mint-Y |
| `theme gtk <nombre>` | Tema GTK |
| `theme icon <nombre>` | Tema de iconos |
| `theme cursor <nombre>` | Tema de cursor |
| `theme cursor-size <16-96>` | Tamaño del cursor, en píxeles |
| `theme cinnamon <nombre>` | Tema de Cinnamon (panel y menús) |
| `theme import <archivo\|carpeta>` | Instala un tema descargado (`.zip`, `.tar.gz`, `.tar.xz`, `.tar.bz2`) |
| `theme folder` | Abre la carpeta de temas |
| `theme list-gtk` / `list-icon` / `list-cursor` / `list-cinnamon` | Lista los temas instalados de cada tipo |
| `theme list-mint-y-colors <claro\|oscuro>` | Colores oficiales de Mint-Y disponibles |

### 🖥️ Panel

| Comando | Qué hace |
| --- | --- |
| `panel accent <#RRGGBB>` | Color de acento del panel |
| `panel bg <#RRGGBB>` | Fondo del panel |
| `panel fg <#RRGGBB>` | Texto del panel |
| `panel menu-bg <#RRGGBB>` | Fondo de los menús |
| `panel menu-fg <#RRGGBB>` | Texto de los menús |
| `panel tooltip-bg <#RRGGBB>` | Fondo de los tooltips |
| `panel tooltip-fg <#RRGGBB>` | Texto de los tooltips |
| `panel gtk-accent <#RRGGBB>` | El mismo acento, pero para todas las apps GTK3/GTK4 |
| `panel opacity <0-100>` | Opacidad del panel, en % |
| `panel height <16-100>` | Alto del panel, en píxeles |
| `panel reset-colors` | Quita la personalización de color del panel (y el acento GTK global, si lo había) |

### 🪟 Escritorio y 🧩 Avanzado

| Comando | Qué hace |
| --- | --- |
| `desktop panel-position <top\|bottom>` | Panel arriba o abajo |
| `desktop window-buttons <preset\|cadena>` | Botones de la ventana — ver presets abajo, o una cadena a medida (p. ej. `close,minimize:maximize`) |
| `desktop list-button-presets` | Lista los presets de botones con su cadena real |
| `desktop hotcorners <sup-izq> <sup-der> <inf-izq> <inf-der>` | Esquina activa en cada una: `none`, `expo`, `scale` o `desktop` |
| `desktop effects <on\|off>` | Efectos al abrir/cerrar ventanas |
| `desktop menu-effects <on\|off>` | Efectos al abrir menús |
| `desktop workspaces <1-20>` | Número de espacios de trabajo |
| `desktop icons <show\|hide>` | Iconos del escritorio |
| `desktop bg-color <#RRGGBB> <mantener\|solo_color>` | Color de fondo: `mantener` lo deja como respaldo detrás de la imagen actual, `solo_color` quita la imagen |

Presets de `window-buttons`: `derecha`, `izquierda`, `gnome`, `mac-clasico`, `compacto`, `menu-izquierda`, `solo-cerrar-izquierda`.

Las esquinas activas y la cadena de botones personalizada tienen su propia pestaña, «Avanzado», separada de «Escritorio» — en la terminal son los mismos comandos `desktop` de arriba.

### ⌨️ Terminal

| Comando | Qué hace |
| --- | --- |
| `terminal apply_palette <nombre>` | Aplica una paleta lista para usar |
| `terminal list` | Lista las paletas disponibles |
| `terminal custom-colors <#fondo> <#texto>` | Colores a medida (cualquiera de los dos puede ir vacío: `""`) |

Paletas incluidas: `nord`, `dracula`, `gruvbox`, `solarized-dark`, `solarized-light`, `monokai`, `one-dark`, `tokyo-night`, `catppuccin-mocha`.

### 🔤 Fuentes

| Comando | Qué hace |
| --- | --- |
| `fonts font <nombre>` | Fuente de la interfaz |
| `fonts monospace <nombre>` | Fuente monoespaciada (terminal, editores) |
| `fonts rendering <rgba\|grayscale\|none> <slight\|medium\|full\|none>` | Antialiasing e hinting |
| `fonts scaling <50-200>` | Escala del texto, en % |

### 💾 Backups y presets

| Comando | Qué hace |
| --- | --- |
| `backup create` | Crea una copia de seguridad ahora |
| `backup list` | Lista las copias de seguridad |
| `backup restore <nombre>` | Restaura una copia de seguridad |
| `preset save <nombre>` | Guarda el estado actual como preset |
| `preset list` | Lista los presets guardados |
| `preset load <nombre>` | Aplica un preset guardado |

Incluye dos presets de fábrica: `default` (una aproximación al aspecto original de Mint) y `nord-dark` (estética fría inspirada en la paleta Nord).

## Compatibilidad

Pensado y probado en **Linux Mint 22.3 Cinnamon**, con sesión gráfica activa. Depende directamente de los esquemas `org.cinnamon.*` de dconf, así que necesita Cinnamon como entorno de escritorio: no funciona en las ediciones Xfce o MATE de Mint, ni en GNOME, KDE u otros entornos. Debería comportarse igual en otras versiones de Mint con Cinnamon y en otras distros que también usen Cinnamon (Debian, Fedora Cinnamon Spin...), pero de momento solo está verificado en 22.3.

| Herramienta | Para qué | ¿Viene de fábrica en Mint 22.3? |
| --- | --- | --- |
| `dconf`, `gsettings`, `gdbus` | Leer y escribir todos los ajustes | Sí |
| `yad` | Interfaz gráfica | No — Color Mint se ofrece a instalarlo |
| `rsync` | Restaurar backups de forma más precisa | Sí (opcional; si falta, usa `cp`) |
| `notify-send` | Notificación de escritorio al aplicar cambios | Sí (opcional) |

## Sobre el idioma

Color Mint está en español: interfaz gráfica, ayuda, mensajes y comentarios del código. No hay versión en inglés todavía.

**Mini roadmap**, sujeto a que haya interés real:

- [ ] Traducción completa de la interfaz, la ayuda (`--help`) y los mensajes al inglés
- [ ] Forma de elegir idioma (detección del sistema o un flag `--lang`)
- [ ] Este README también en inglés

Si te interesaría una versión en inglés, dilo en un issue — es la señal que necesito para priorizarlo.

## Ver también

Otra herramienta del mismo autor: [**Scriptya**](https://github.com/filonux/Scriptya), que convierte cualquier script en una app independiente con su propio icono, integrada en el menú de Cinnamon y/o en el escritorio, y de paso deja lanzarlo, actualizarlo o desinstalarlo desde un único menú.

## Contribuir

Los issues y pull requests son bienvenidos — hay plantillas en `.github/` para reportar errores, proponer mejoras o enviar un PR. La guía completa está en [CONTRIBUTING.md](.github/CONTRIBUTING.md). Este proyecto sigue el [Código de Conducta](.github/CODE_OF_CONDUCT.md) del repositorio; para reportar un problema de seguridad en vez de abrir un issue público, consulta [SECURITY.md](.github/SECURITY.md).

## Licencia

GPLv3. Consulta el archivo [LICENSE](LICENSE).
Copyright © 2026 Filonux.

---

Hecho por **Filonux**.
