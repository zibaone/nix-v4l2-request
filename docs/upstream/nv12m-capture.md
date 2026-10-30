# Support NV12M en capture — analyse pour une soumission amont

Correctif : `0001-libavcodec-v4l2-request-support-nv12m-capture.patch` (ce dossier).
Cible technique : série LibreELEC `v4l2-request` appliquée à FFmpeg 6.1.6 — les
fichiers `libavcodec/v4l2_request.{c,h}` n'existent pas dans FFmpeg nu.
Cible politique : LibreELEC d'abord (voir § 5), Forgejo FFmpeg ensuite.

État du fichier : appliqué sans fuzz (`patch -p1 --fuzz=0`) sur l'arbre
FFmpeg 6.1.6 + série LibreELEC ; le code NV12M a été compilé contre les en-têtes
UAPI réels (`-Wall -Wextra`, aucun avertissement nouveau), avec un test qui
vérifie le descripteur produit (2 objets, 2 plans, régression mono-plan
incluse). Ce n'est pas un build FFmpeg complet : voir § 6.

---

## 1. Ce que le patch change

Cinq endroits, tous additifs. Aucun format mono-plan ne change de comportement.

| Endroit | Changement | Pourquoi |
|---|---|---|
| table `v4l2_request_capture_pixelformats[]` | entrée `V4L2_PIX_FMT_NV12M` (`'NM12'`) → `DRM_FORMAT_NV12`, `num_planes = 2` ; nouvelle colonne `num_planes` | le pilote n'annonce que ce format en capture |
| `v4l2_request_set_format()` | `num_planes` lu dans la table au lieu de `1` en dur | `S_FMT` doit demander 2 plans pour que le pilote négocie le layout multi-plan |
| `v4l2_request_queue_buffer()` / `_dequeue_buffer()` | `planes[VIDEO_MAX_PLANES]`, `buffer.length = buf->nb_planes` | `videobuf2` refuse un tableau de plans trop court ; `length` doit refléter le nombre négocié |
| `v4l2_request_buffer_alloc()` | mémorise `nb_planes`, `size_plane1`, `bytesperline(_plane1)` depuis `VIDIOC_CREATE_BUFS` ; un `VIDIOC_EXPBUF` **par plan** ; refus explicite si > 2 plans | chaque plan V4L2 est un objet buffer distinct, donc un dmabuf distinct |
| `v4l2_request_set_drm_descriptor()` | si `nb_planes > 1` : **deux** `AVDRMObjectDescriptor`, `layer->planes[1].object_index = 1`, `offset = 0` | deux dmabufs distincts ne peuvent pas être deux plans d'un même objet |

`V4L2RequestBuffer` gagne `fd_plane1`, `size_plane1`, `bytesperline`,
`bytesperline_plane1`, `nb_planes` ; `v4l2_request_buffer_free()` ferme le
second fd, `v4l2_request_frame_alloc()` l'initialise à `-1`.

Ce qui **ne** change pas : NV12, `SUNXI_TILED_NV12`, NV16, P010, NV15/NV20 et
AFBC gardent `nb_planes == 1` et le layout historique à un objet (deux plans à
`offset = pitch * height` pour les formats non-AFBC). `cedrus`, `rkvdec`,
`hantro` doivent donc se comporter exactement comme avant — c'est le test de
non-régression à joindre à la soumission.

## 2. Pourquoi c'est le pilote qui impose NV12M, et pas l'inverse

Le pilote `meson-amvdec` (Amlogic GXL/GXM, noyau LibreELEC) n'expose que
`NV12M` dans sa liste de formats de capture (`pixfmts_cap`) : la luminance et la
chrominance sont deux plans V4L2, exportés en deux dmabufs.

La négociation de `v4l2_request_select_capture_format()` est pourtant
indirecte : `G_FMT` → si le format courant est dans la table, on le garde ;
sinon `ENUM_FMT` sur le pilote, et on retient le premier format annoncé
présent dans la table. Sans entrée `NV12M`, aucun des deux chemins ne matche :

```
v4l2_request_select_capture_format: select capture format failed     (AV_LOG_DEBUG)
No V4L2 media device found for S264                                  (AV_LOG_INFO)
```

Le hwaccel n'est jamais instancié alors que le matériel décode le H.264/HEVC
par la Request API.

**« Pourquoi ne pas plutôt exposer du mono-plan côté pilote ? »** Parce qu'un
nœud V4L2 est mono-plan **ou** multi-plan pour toute sa vie : ce sont deux
capacités exclusives (`V4L2_CAP_VIDEO_M2M` vs `V4L2_CAP_VIDEO_M2M_MPLANE`) et
deux structures d'API (`v4l2_pix_format` vs `v4l2_pix_format_mplane`). Un
pilote ne « choisit » pas le mode par format : `NV12M` est précisément le nom
du format multi-plan de NV12, et `meson-amvdec` annonce `NV12M` parce que le
matériel produit deux allocations distinctes (chroma avec son propre pitch et
ses propres contraintes d'alignement). Ajouter un chemin mono-plan au pilote
signifierait un second format, non produit par le matériel, à maintenir et à
tester pour satisfaire un seul client — et cela changerait l'ABI visible des
autres clients du nœud (`v4l2-ctl`, GStreamer, V4L2 direct). Le mécanisme
prévu côté hwaccel, c'est la table de formats : c'est elle qu'on étend.

## 3. Objections attendues

| Objection | Réponse |
|---|---|
| « Corrigez le pilote, pas FFmpeg. » | Voir § 2 : le nœud est multi-plan par construction et `NV12M` est le seul format annoncé. Le hwaccel sait déjà décrire des formats par table ; il lui manquait l'entrée. |
| « Deux objets DRM cassent `drmModeAddFB2`. » | Non : `AVDRMFrameDescriptor` référence chaque plan par `layer->planes[i].object_index`, et `drmModeAddFB2()` prend un `handles[]`/`pitches[]`/`offsets[]` par plan. Les consommateurs DRM PRIME (Kodi, mpv) construisent le framebuffer depuis ces trois champs, pas depuis « objet 0 uniquement ». Le layer reste `DRM_FORMAT_NV12`. |
| « Pourquoi deux objets et pas deux plans d'un seul objet à `offset = 0` ? » | Impossible : deux plans V4L2 exportés séparément sont deux GEM handles distincts. Un `AVDRMPlaneDescriptor` ne peut désigner qu'un objet via `object_index`. |
| « Le `bytesused` du second plan. » | Il n'y en a pas : sur une file de capture, `bytesused` est rempli par le pilote au `DQBUF`. Le patch ne touche pas `planes[1].bytesused` (laissé à 0 par l'initialisation). |
| « `planes[2]` en dur. » | Corrigé : `VIDEO_MAX_PLANES` (8), la borne du sous-système V4L2, et `length` = nombre réellement négocié. |
| « Et un format à 3 plans ou plus ? » | Refus explicite dans `v4l2_request_buffer_alloc()` (`> 2` → `AVERROR(EINVAL)`) plutôt qu'un dépassement silencieux. `AV_DRM_MAX_PLANES` vaut 4 : l'extension est mécanique le jour où un pilote en a besoin. |
| « Ça déplace la négociation pour les pilotes existants ? » | Non : `G_FMT` puis `ENUM_FMT` restent inchangés ; `NV12M` n'est retenu que si le pilote l'annonce. Là où NV12 est annoncé d'abord, NV12 reste choisi. |
| « Pourquoi pas un `AV_PIX_FMT_NV12M` ? » | `sw_format` décrit le contenu logiciel d'une frame `DRM_PRIME`, pas le découpage en buffers. Le contenu reste du NV12 ; c'est le descripteur qui porte le découpage. |
| « `meson-amvdec` n'est pas amont, donc pas de consommateur amont. » | Exact, et c'est l'argument central de § 5 : la cible est LibreELEC. Un envoi isolé à ffmpeg-devel serait refusé pour cette raison, pas pour un défaut du patch. |
| « `buf->buffer.m.planes` pointe sur un tableau de pile dans `buffer_alloc()`. » | Défaut pré-existant de la série, sans effet ici (le pointeur n'est jamais relu ; `QBUF`/`DQBUF` construisent leur propre `v4l2_buffer`). À traiter dans un patch séparé, pas en contrebande dans celui-ci. |

## 4. Comment le vérifier

Build : `--enable-v4l2-request --enable-libudev`, `libdrm` et `libudev` en
dépendances (cf. `pkgs/ffmpeg-v4l2request/default.nix`).

Côté pilote, d'abord — c'est ce qui rend le diagnostic non ambigu :

```sh
v4l2-ctl -d /dev/video1 --list-formats        # doit lister 'NM12'
```

Puis le décodage, sur 10 s de 1080p30 (300 images) :

```sh
ffmpeg -hide_banner -v debug \
       -hwaccel drm -hwaccel_output_format drm_prime \
       -i in.h264 -map 0:v -f null -
```

Sortie attendue :

- `v4l2_request_init_context: pixelformat=NM12 width=1920 height=1080
  bytesperline=… sizeimage=… num_planes=2` — c'est la preuve que le format a
  été négocié en multi-plan, pas seulement accepté ;
- aucune occurrence de `select capture format failed` ;
- ~0,46 s de CPU pour 300 images (banc Amlogic GXL/GXM, `meson-amvdec`) ; l'ordre
  de grandeur à retrouver sur une autre cible est ~0,9 s de CPU pour 10 s de
  1080p — il dépend de la machine et du chemin de consommation, donc à rejouer
  plutôt qu'à recopier.

Contre-épreuve, même commande sans le patch :

```
v4l2_request_select_capture_format: select capture format failed
No V4L2 media device found for S264
```

Non-régression mono-plan, à joindre : la même commande sur `cedrus`
(Allwinner) ou `rkvdec` (Rockchip) doit produire les mêmes temps qu'avant le
patch. C'est le seul point qui intéresse un relecteur qui ne possède pas de
matériel Amlogic.

Limite de la vérification `-f null` : elle prouve l'absence d'erreur de
décodage et le coût CPU, pas la justesse des pixels. Le contenu se contrôle
côté consommateur (Kodi) ou en important le dmabuf dans un outil DRM ; FFmpeg
ne sait pas transférer une frame `DRM_PRIME` vers le CPU (`hwdownload` n'a pas
de chemin `drm`).

## 5. Où l'envoyer

**1. LibreELEC (cible réelle).** C'est là que la série vit, que `meson-amvdec`
est supporté et que le couple pilote/hwaccel est utilisé. Le patch se pose dans
`packages/multimedia/ffmpeg/patches/v4l2-request/` (le répertoire n'est appliqué
qu'aux cibles qui activent `v4l2-request` dans `package.mk`), ou en PR contre
`LibreELEC.tv`. Le diff seul suffit ; l'en-tête mail ne gêne pas `patch -p1`.

**2. Forgejo FFmpeg, PR #20847** (« WIP: Add V4L2 Request API hwaccels… »,
branche `Kwiboo/FFmpeg:v4l2request-v3`). Plutôt qu'un envoi isolé : un commentaire
qui propose le correctif, en signalant qu'il est prêt à être rebasé sur la
branche. La branche v3 a déjà `V4L2_PLANES_MAX 2` et passe `length` en dur à 2
sur toute file multiplan — notre version passe le nombre négocié, ce qui reste
correct que le noyau compare `length < num_planes` (videobuf2) ou `==`.

**3. ffmpeg-devel, seulement si la série est reprise.** Un `[PATCH]` NV12M seul
n'a pas de consommateur amont : il sera refusé poliment pour cette raison. Si
la série repart, la procédure est `git format-patch` + `git send-email`, texte
brut, pas de pièce jointe, s'abonner à la liste avant d'envoyer, et le patch
doit être rebasé sur la branche de la série, pas sur la série LibreELEC 6.x.

Dans les deux premiers cas, mettre en copie les auteurs de la série
(Jonas Karlman, Jernej Škrabec) : ce sont eux qui décideront de la forme
retenue, et une revue par l'auteur du hwaccel vaut mieux qu'un fil orphelin.

Avant tout envoi, remplacer les trois espaces réservés du fichier :
`From:` / `Date:` / `Signed-off-by:` (le `Signed-off-by` doit porter le nom et
l'adresse réels de l'auteur, c'est un DCO, pas une formalité). Le `From
0000000…` de la première ligne est un marqueur `git format-patch` standard.

## 6. Ce qui n'est pas prouvé

- Le code mesuré sur le banc est celui du patch du dépôt (`0002`) ; la version
  soumise n'en diffère que par les points de § 3 : taille des tableaux de plans,
  `num_planes` lu dans la table, suppression du `bytesused / 2` mort (il valait
  toujours 0 sur une file de capture), commentaires. Le comportement sur le
  chemin NV12M est identique, mais c'est cette version-là qu'il faut rejouer.
- Les chiffres de § 4 viennent du banc, pas d'une mesure rejouée pour ce
  document ; le `README.md` du dépôt porte encore la mention « décodage non
  validé sur matériel ». À rejouer et à consigner avant l'envoi.
- Seul H.264 8 bits / 1080p a été mesuré. HEVC et VP9 empruntent le même chemin
  de capture mais ne sont pas mesurés avec `NV12M`.
- Pas de `P010M` (10 bits multi-plan) dans la table : hors périmètre.
- Pas de test avec un pitch chroma différent du pitch luma ; le code le gère
  (`bytesperline_plane1`, repli sur `bytesperline`), mais ce n'est pas exercé.
- Pas de test des formats à plus de deux plans : refusés explicitement.
