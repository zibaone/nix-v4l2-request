# nix-v4l2-request

Paquets Nix pour le décodage matériel **stateless V4L2 Request** : FFmpeg 6.1
patché, et Kodi 21.3 qui l'utilise.

> **Statut : décodage validé sur H618 réel ; affichage Kodi du VP9 en cours.**
> Le décodage FFmpeg `-hwaccel drm` est mesuré sur Orange Pi Zero 3 (H264, HEVC,
> VP8, MPEG2, VP9 à 27-30 fps en 1080p). L'affichage Kodi du VP9 reste bloqué
> par l'absence de fencing VPU↔GPU : le patch fence natif (0006) affiche mais
> coûte 30-44 % de `wa` et a été retiré. Le correctif de fond est spécifié dans
> [`docs/specs/drmprime-explicit-fencing.md`](docs/specs/drmprime-explicit-fencing.md).

## Périmètre

Ce dépôt fournit **deux paquets** (et une variante du second), rien d'autre :

- `ffmpeg-v4l2request` — FFmpeg 6.1.6 + série LibreELEC `v4l2-request` ;
- `kodi` — `kodi-gbm` 21.3 lié à ce ffmpeg, avec le backport xbmc#25467 ;
- `kodi-wayland` — le même Kodi, mêmes patches, fenêtrage Wayland
  (`windowing = "wayland"`) : le paquet à consommer si l'on remet un compositeur
  devant le lecteur. Voir `docs/fenetrage-kodi-gbm.md` ;
- `kodi-kiosk` — le même kodi lié aux paquets système élagués de
  `overlays.kiosk`, pour qu'une image kiosque n'ait qu'une pipewire
  (`kodi-kiosk-wayland` en est la variante Wayland).

Il ne fournit **ni noyau, ni image, ni module NixOS**. Il ne dépend d'aucun dépôt
de noyau : la compilation n'a besoin que des en-têtes V4L2 de `linux-headers`.
Le noyau n'intervient qu'à l'exécution — driver `cedrus`, `/dev/media0`, API
Request.

Écrit pour Allwinner H616/H618 (Orange Pi Zero 3, driver `cedrus`), mais rien
n'est propre à ce SoC : la même série couvre `rkvdec` (Rockchip), `hantro`
(i.MX8M), `meson-vdec`. Le nom suit l'API amont, pas la carte.

## Pourquoi ces patches

Nixpkgs n'expose que `withV4l2` (libv4l2) et `withV4l2M2m` (API *stateful*). Les
décodeurs stateless passent par la **Request API**, dont le support n'existe
qu'en aval de FFmpeg.

| pièce | ce qu'elle fait |
|---|---|
| `pkgs/ffmpeg-v4l2request` | `--enable-v4l2-request` + hwaccels `h264_v4l2request` / `hevc_v4l2request` |
| `pkgs/kodi` | `FindHWConfig()` accepte `pix_fmt = DRM_PRIME` + `HW_DEVICE_CTX`, sans exiger `device_type == DRM` |

Le second patch est indispensable pour la variante FFmpeg 7 (série LibreELEC
master), où `device_type` devient `V4L2REQUEST` ; avec la série 6.x il est sans
effet de bord, Kodi 21.3 accepte déjà `DRM`.

## Utilisation

```bash
nix build .#kodi                   # kodi-gbm + ffmpeg v4l2-request
nix build .#kodi-kiosk             # idem, lié aux paquets système élagués
nix build .#ffmpeg-v4l2request     # la couche ffmpeg seule
nix build .#checks.$(nix eval --impure --raw --expr builtins.currentSystem).hwconfig
```

`kodi` et `kodi-kiosk` ne diffèrent que par les paquets qu'ils lient : la
seconde variante utilise `pipewire` élagué (niveau 2), donc une image qui
applique aussi `overlays.kiosk` n'embarque **qu'une** copie de pipewire au lieu
de deux. C'est la variante que consomme une image kiosque ; `kodi` reste la
variante neutre.

## Le gate `hwconfig`

Test C (`pkgs/ffmpeg-v4l2request/test-hwconfig.c`) qui interroge
`avcodec_get_hw_config()` et exige, pour h264 **et** hevc : `pix_fmt =
DRM_PRIME`, méthode `HW_DEVICE_CTX`, `device_type = DRM`. C'est exactement le
contrat que `FindHWConfig()` de Kodi 21.3 vérifie.

`ffmpeg -hwaccels` ne peut pas servir de gate : il liste les `AVHWDeviceType`, et
`V4L2REQUEST` n'existe que dans la série 7+.

## Le réglage qui commande tout : `videoplayer.useprimedecoder`

Avoir le bon ffmpeg et le bon patch ne suffit pas. Dans Kodi 21.3,
`CDVDVideoCodecDRMPRIME::Create()` renvoie `nullptr` tant que
`videoplayer.useprimedecoder` est faux
(`xbmc/cores/VideoPlayer/DVDCodecs/Video/DVDVideoCodecDRMPRIME.cpp`) : le
décodeur n'est jamais instancié, Kodi décode en CPU et **ne le signale pas**.

Le défaut amont est `<default>false</default>`
(`system/settings/linux.xml`). `pkgs/kodi/patches/0002-linux-default-useprimedecoder.patch`
le bascule à `true`, et un `postPatch` vérifie la valeur finale dans le fichier
— un patch de données peut s'appliquer ailleurs sans échouer.

Conséquences :

- le réglage reste visible dans l'UI (niveau 2) une fois le codec enregistré :
  on peut le désactiver sans recompiler ;
- si le décodeur n'ouvre pas son device (`/dev/dri/renderD128` par défaut,
  `$KODI_RENDER_NODE` sinon — `DVDVideoCodecDRMPRIME.cpp:307-327`), `Open()`
  renvoie `false` : `CDVDFactoryCodec` passe au décodeur matériel suivant puis,
  `CODEC_ALLOW_FALLBACK` étant posé par défaut, au décodage logiciel. Le
  basculement n'est donc pas irréversible — mais il coûte une tentative et une
  ligne d'erreur par ouverture, ce qui est le prix d'un défaut à `true` sur une
  machine sans VPU exploitable (x86 sans `/dev/video*` en Request API).

## Élagage

Deux niveaux, séparés volontairement. Le détail chiffré et les leviers restants
sont dans [`docs/poids-et-optimisations.md`](docs/poids-et-optimisations.md).

**Niveau 1 — appliqué par défaut** (`overlays/v4l2-request.nix`), ne touche que
l'arbre de kodi : `mesa-demos` remplacé par un stub, `libdecor` sans le plugin
GTK (→ pas de `gtk+3`), `cwiid` sans `wmgui` (GTK2). Les encodeurs ffmpeg sont
désactivés (`x264`, `x265`, `libvpx`, `libaom`, `svt-av1`, `rav1e`) : jamais
utilisés en lecture, décodage complet (AV1 via `dav1d`). `ffplay` et SDL2 sont
coupés — inutiles dans une image kiosque, et ils tiraient GTK4. Kodi perd en
plus `bluez`, `libplist` et `lirc`.

Ce niveau ne contient **plus** d'entrée `libavif` ni `Pillow` : kodi 21.3 ne lie
pas libavif (zéro occurrence dans sa fermeture, `libaom` compris). Les deux
overrides ne gagnaient rien et fuyaient par une chaîne de *documentation* —
`libavif → gd → graphviz → wayland → wayland-protocols → mesa,
vulkan-loader → ffmpeg-headless → pipewire` — soit neuf paquets d'infrastructure
reconstruits, `mesa` en tête. Mesure : sans eux, `pipewire` revient exactement
au dérivé de nixpkgs (`71mvxq2s…` au lieu de `wxq58hhx…`).

**Niveau 2 — `overlays.kiosk`, à demander explicitement** : `pipewire` élagué
(gstreamer, bluez5, libcamera), `wlroots` sans XWayland, `v4l-utils` sans ses
GUI Qt, `ffmpeg-headless` sans encodeurs. Ce sont des paquets système : les
appliquer d'office retirerait l'audio Bluetooth, le XWayland ou les webcams à
quiconque importe le flake. D'où un second overlay, opt-in :

```nix
nixpkgs.overlays = [
  nix-v4l2-request.overlays.default
  nix-v4l2-request.overlays.kiosk   # seulement si l'on veut un kiosque
];
```

Il sert aussi de **cible de construction pour la CI** : `checks.<system>.kiosk-closure`
construit `mesa`, `pipewire`, `wireplumber`, `v4l-utils` et `ffmpeg-headless`
avec les deux overlays, si bien que le cache contient les dérivations exactes
dont une image a besoin. Sans ça, le moindre élagage côté image change un chemin
de store que personne n'a mis en cache, et il faut recompiler `mesa` sous
émulation — 1 h 30 mesurées.

Deux corrections dans cette liste : `sdl3` y figurait alors qu'il n'apparaît
dans aucune fermeture d'image (`withSdl2 = false`), donc il était reconstruit à
chaque build pour rien ; `wireplumber` manquait, absent du cache et pourtant
présent dans la fermeture d'exécution de l'image.

`cage` et `wlroots` y figurent encore alors que l'image ne les lance plus depuis
le passage du kiosque en **GBM direct** (voir `docs/fenetrage-kodi-gbm.md`) : ils
restent dans la cible tant que ce retrait n'est pas fait, mais ne maintiennent
plus qu'un cache pour une architecture abandonnée.

## État vérifié

| vérification | résultat |
|---|---|
| `nix build .#packages.aarch64-linux.ffmpeg-v4l2request` | construit en CI (runner ARM natif) |
| `nix build .#packages.aarch64-linux.kodi` | construit en CI |
| `nix build .#packages.aarch64-linux.kodi-kiosk` | construit en CI (variante consommée par l'image) |
| gate `hwconfig` (h264 + hevc) sur aarch64 | passe : `pix_fmt=drm_prime methods=HW_DEVICE_CTX device_type=drm` |
| gate `hwconfig` sur x86_64 | construit par le job `gate-x86_64` (runner x86 natif) |
| `nix flake check` (formatage inclus) | bloque la CI et protège `master` |
| **décodage sur H618 réel** (`ffmpeg -hwaccel drm`, 1080p) | **mesuré** : H264 29 fps, HEVC 28, VP8 30, MPEG2 27, VP9 29 |
| **affichage Kodi VP9** | image avec le patch 0006 ; `wa` 30-44 % → patch retiré ; fencing noyau spécifié |

Ce qui est mesuré (Zero 3, noyau 7.0.14 + patch cedrus VP9) :

1. `v4l2-ctl --list-formats-ext` expose `S264`, `S265`, `VP8F`, `VP9F`, `MG2S` ;
2. `dmesg` montre le VPU `1c0e000.video-codec` et cedrus ;
3. `kodi.log` contient `using decoder Google VP9` et `drm hwdevice context` ;
4. `ffmpeg -hwaccel drm` : 29 fps en VP9 1080p (`0.97x`, utime 10,2 s pour
   10 s) ; 44 fps en 1412×1080 (`1.44x`).

Ce qui reste ouvert :

- l'affichage Kodi du VP9 sans lag : fencing VPU↔GPU, voir la spec ;
- le VP9 10-bit (P010/AFBC, patch 0413) ;
- les mesures Kodi par codec (les non-régressions ffmpeg sont faites).

## Provenance, auteurs, licences

| élément | auteur | source | licence |
|---|---|---|---|
| série FFmpeg `v4l2-request` | projet **LibreELEC** (chaque patch garde la signature de son auteur) | [`LibreELEC.tv` @ `7cf13a1fbde5`](https://github.com/LibreELEC/LibreELEC.tv/blob/7cf13a1fbde5/packages/multimedia/ffmpeg/patches/v4l2-request/ffmpeg-001-v4l2-request.patch), `ffmpeg-001-v4l2-request.patch`, 170 543 octets, `sha256:0f638d58feb19dfd…` | GPL-2.0 |
| rebase 6.0.1 → 6.1.6 | ce dépôt | `pkgs/ffmpeg-v4l2request/patches/0001-v4l2-request-ffmpeg-6.1.6.patch` — le diff source appliqué, suivi des seules adaptations, listées en tête de fichier | GPL-2.0 |
| patch Kodi | **Jonas Karlman** ([@Kwiboo](https://github.com/Kwiboo)), commit `ed324259c8b9` | [xbmc#25467](https://github.com/xbmc/xbmc/pull/25467) « CDVDVideoCodecDRMPRIME: Fix use of v4l2request hwdevice », 1 fichier, +29/−25, mergée le 2024-12-21 | GPL-2.0 |
| `test-hwconfig.c`, flake, overlays, CI | ce dépôt | — | MIT (voir `LICENSE`) |

Aucun patch n'est réécrit de mémoire : le fichier FFmpeg est le diff source
appliqué, la liste des adaptations est en tête du fichier, et l'empreinte du
patch d'origine permet de le vérifier.

## CI

`.github/workflows/build.yml` construit les paquets sur un runner ARM natif
(`ubuntu-24.04-arm`), chronomètre chaque étape et publie les tailles réelles
(`nix path-info -S`) dans le résumé du run. Le montage de `/mnt` sur `/nix` est
conditionnel : les runners actuels ont 145 Go sur `/`, le bind ne sert que si
`/mnt` est un volume séparé.

Le workflow tourne sur `push` vers `master`, sur `pull_request` et à la demande.
`master` exige que ces jobs passent avant toute fusion.

Trois gates, plus un job de parité :

1. `nix flake check -L` — évaluation complète du flake **et** formatage
   (`checks.<system>.formatting` lance `nixfmt --check` sur `flake.nix`,
   `overlays/*.nix` et `pkgs/*/default.nix`). Un fichier mal formaté fait
   échouer la CI, pas seulement un `nix fmt` local oublié ;
2. `checks.<system>.hwconfig` — le contrat hwaccel ;
3. `checks.<system>.kiosk-closure` — les paquets système élagués, poussés au
   cache, avec un **contrôle de narinfo** après le push : le daemon de
   `cachix-action` a déjà annoncé « Pushed » des chemins qu'il n'envoyait pas
   (404 vérifiés), donc le badge vert ne suffit pas ;
4. job `gate-x86_64` (`ubuntu-latest`) : le même gate `hwconfig` construit en
   x86 natif. Il était annoncé « passe » dans ce README sur la foi d'une mesure
   locale, sans qu'aucune CI ne le construise — c'est corrigé.

`concurrency` annule le run précédent sur la même réf : un push pendant un build
de 50 min ne doit pas en lancer un second.
