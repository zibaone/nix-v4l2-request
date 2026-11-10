# Spec — fencing explicite VPU↔GPU pour DRMPRIME (VP9, H616/H618)

> Statut : proposition (Draft).
> Date : 2026-11-10.
> Périmètre : chemin VP9 cedrus → DRM PRIME → `RendererDRMPRIMEGLES` de Kodi,
> sur OrangePi Zero 3 (H618). S'applique aux autres codecs DRMPRIME.
> Sources : `docs/vp9-explicit-fencing.md` (ce dépôt) ; notes internes nixbian
> (plan média H616/H618, rapport P0 VP9, inventaire codecs).

## 1. Contexte et problème

Le VPU cedrus écrit ses images NV12 dans des buffers capture exportés en
dma-buf, que panfrost importe comme textures. Il n'existe **aucun fencing
implicite entre le VPU et le GPU** : rien n'empêche le VPU d'écraser un buffer
pendant que le GPU le lit encore.

Kodi compense dans le renderer avec une fence EGL, et les deux variantes
échouent sur panfrost :

- `EGL_SYNC_FENCE_KHR` (comportement d'origine) : la fence ne signale pas
  (47 `timeout waiting` pour 300 frames), l'image VP9 n'est pas affichée ;
- `EGL_SYNC_NATIVE_FENCE_ANDROID` + `NeedBuffer` qui interroge
  `eglGetSyncAttribKHR` à chaque frame (patch local 0006) : l'image s'affiche,
  mais `wa` monte à 30-44 % et les menus rament.

La cause n'est ni le codec VP9 ni le driver cedrus : c'est l'absence de
synchronisation entre deux moteurs qui partagent un dma-buf, et le fait que le
contrôle soit fait côté userspace dans le chemin chaud du rendu.

## 2. Objectifs et non-objectifs

### Objectifs

- Afficher le VP9 1080p en DRMPRIME sans `timeout waiting`.
- Supprimer l'attente GPU du chemin chaud du renderer (plus de polling de
  fence par frame).
- Ne pas ajouter de frame de latence.
- Ne pas régresser H264/HEVC/VP8/MPEG2, ni le rendu des menus.
- Rester publiable en amont (GPL-2.0, pas de blob, UAPI existante).

### Non-objectifs

- Le 10-bit VP9 (patch 0413) : hors périmètre.
- Le rendu vidéo sans composition GPU (plan DRM direct) : hors périmètre.
- Une nouvelle UAPI V4L2 « in-fence » : non nécessaire.
- Vulkan : écarté (PanVK expérimental sur Mali-G31, pas de renderer Vulkan
  dans Kodi, et le problème de synchronisation resterait identique).

## 3. Exigences

### Fonctionnelles

- **F1** — Une frame VP9 1080p lue en DRMPRIME affiche l'image, sans
  `timeout waiting` dans `kodi.log`.
- **F2** — Le VPU ne réécrit jamais un buffer capture dont le GPU n'a pas
  fini la lecture.
- **F3** — En cas d'échec de la synchronisation (fence non signalée), le
  décodeur ne se bloque pas indéfiniment : dégradation contrôlée après un
  délai borné.
- **F4** — Le comportement est identique pour les autres codecs DRMPRIME
  (H264, HEVC, VP8, MPEG2).

### Non fonctionnelles

- **N1** — Aucun appel de fence/poll dans `NeedBuffer` ou dans la boucle de
  rendu.
- **N2** — `wa` CPU < 5 % pendant la lecture 1080p30, `bi`/`bo` négligeables.
- **N3** — Latence vidéo inchangée (pas de frame supplémentaire).
- **N4** — Coût par frame : au plus une création de fence native + un ioctl
  d'import + un `close`, côté Kodi ; une attente IRQ côté noyau.
- **N5** — Aucune nouvelle UAPI ; utiliser `DMA_BUF_IOCTL_IMPORT_SYNC_FILE`
  (déjà dans `include/uapi/linux/dma-buf.h`).
- **N6** — Code kernel GPL-2.0, style noyau, checkpatch propre ; patch Kodi
  GPL-2.0-or-later, dans le style du fichier.

## 4. Architecture

```
frame N :
  cedrus écrit NV12 dans le buffer B (vb2 capture, exporté dma-buf)
  ffmpeg expose B en DRM PRIME ; Kodi l'importe en texture EGL
  Kodi : draw GLES qui lit B
    ├─ CreateGPUFence()        (fence native après le draw)
    ├─ fd = FlushFence()       (eglDupNativeFenceFDANDROID)
    ├─ ioctl(B.fd, DMA_BUF_IOCTL_IMPORT_SYNC_FILE, {DMA_BUF_SYNC_READ, fd})
    └─ close(fd)
  NeedBuffer(B) → true  (B rendu au décodeur)
frame N+1 :
  ffmpeg re-queue B dans la capture V4L2
  cedrus, avant de programmer le VPU :
    └─ dma_resv_wait_timeout(B.resv, DMA_RESV_USAGE_READ, …)
         attend la fence READ du GPU importée au frame N
```

Le contrat est porté par le `dma_resv` du dma-buf, partagé entre l'export vb2
(`vb2_plane.dbuf->resv`) et l'import panfrost (même `dma_buf`). Kodi publie la
fence de lecture GPU ; le noyau l'attend avant l'écriture VPU.

## 5. Contrat dma-buf

- **Qui crée la fence** : le renderer Kodi, après le draw, via
  `CEGLFence::CreateGPUFence()` (native fence `EGL_SYNC_NATIVE_FENCE_ANDROID`)
  puis `FlushFence()` qui duplique le fd (`eglDupNativeFenceFDANDROID`).
- **Usage** : `DMA_BUF_SYNC_READ` — la fence signifie « le GPU a fini de lire ».
  `DMA_BUF_IOCTL_IMPORT_SYNC_FILE` l'ajoute au `dma_resv` avec
  `DMA_RESV_USAGE_READ` (vérifié dans `drivers/dma-buf/dma-buf.c`).
- **Attente** : le consommateur qui va **écrire** le buffer attend toutes les
  fences de synchronisation implicite. Dans l'API actuelle,
  `dma_resv_wait_timeout(resv, DMA_RESV_USAGE_READ, …)` renvoie aussi les
  fences `WRITE` et `KERNEL` (commentaire de `include/linux/dma-resv.h`) :
  c'est l'ensemble requis.
- **Durée de vie du fd** : `IMPORT_SYNC_FILE` prend une référence sur la
  fence ; le fd doit être fermé juste après l'ioctl. Ne jamais fuir de fd
  (le patch 0003 a déjà corrigé une fuite sur ce chemin).
- **Non-export** : si le buffer n'a pas de `dbuf` (`vb2_plane.dbuf == NULL`),
  il n'y a pas de fence à attendre ; comportement actuel conservé.

## 6. Composant A — renderer Kodi

Fichier : `xbmc/cores/VideoPlayer/VideoRenderers/HwDecRender/RendererDRMPRIMEGLES.cpp`.

- Dans `Render`, après les commandes GL du draw (à l'emplacement actuel de
  `buf.fence->DestroyFence(); buf.fence->CreateFence();`, ~l.392) :
  créer la fence native, récupérer le fd, importer sur chaque objet du
  `AVDRMFrameDescriptor` du buffer, fermer le fd.
- `NeedBuffer` (~l.165) retourne `true` : la libération ne dépend plus d'une
  fence userspace.
- Le chemin `EGL_SYNC_FENCE_KHR` (`CreateFence`/`IsSignaled`) n'est plus
  utilisé pour la libération ; il peut être retiré de ce renderer.
- Garde de compilation : le code natif est sous
  `#if defined(EGL_ANDROID_native_fence_sync) && defined(EGL_KHR_fence_sync)`,
  comme dans `CEGLFence`.
- Repli si `FlushFence()` échoue : conserver le comportement fence EGL ou
  basculer sur le N+1 (voir §8).

## 7. Composant B — cedrus

Fichier : `drivers/staging/media/sunxi/cedrus/cedrus_dec.c` (ou
`cedrus_video.c`), dans `cedrus_device_run`, avant de programmer le VPU.

- Récupérer le buffer capture (`v4l2_m2m_next_dst_buf`) et son
  `vb2_buf.planes[0].dbuf`.
- Si `dbuf` non nul : `dma_resv_wait_timeout(dbuf->resv,
  DMA_RESV_USAGE_READ, true, msecs_to_jiffies(500))`.
- `ret == 0` (timeout) : `dev_warn` et continuer (dégradation contrôlée).
- `ret < 0` (`-ERESTARTSYS`) : laisser le m2m gérer l'annulation.
- Ne pas attendre dans `buf_queue` (contexte ioctl) : le job m2m est un
  kthread, il peut dormir.

## 8. Modes de défaillance et dégradation

| Cas | Comportement |
|---|---|
| `eglDupNativeFenceFDANDROID` indisponible/échoue | repli sur la fence EGL actuelle, puis N+1 si insuffisant |
| Fence jamais signalée | timeout 500 ms, warning, poursuite (pas de blocage) |
| Buffer non exporté | pas d'attente |
| Import en double | à éviter : un import par buffer et par frame |
| Fin de stream | les fences non signalées sont libérées avec le `dma_resv` |
| Régression codec | le chemin de release est commun ; tester H264/HEVC/VP8/MPEG2 |

## 9. Critères d'acceptation

1. Lecture VP9 1080p : `grep -c "timeout waiting"` = 0, image affichée.
2. `vmstat 2 10` : `wa` < 5 %, `bi`/`bo` < 1 Mo/s.
3. Débit : 29-30 fps sur le sample 1080p30 ; IRQ `1c0e000.video-codec`
   incrémentée de ~300 pour 300 frames.
4. Menus : navigation fluide pendant la lecture (pas de `wa` GPU).
5. Non-régressions : H264/HEVC/VP8/MPEG2 toujours décodés matériellement et
   affichés.
6. A/B documenté : sans 0006 (pas d'image) vs 0006 (lag) vs spec (image +
   fluide).
7. `dma_buf/bufinfo` (debugfs) montre une fence panfrost sur le buffer
   pendant la lecture.

## 10. Compatibilité et stratégie amont

- **Kodi** : patch autonome « RendererDRMPRIMEGLES: import the GPU read fence
  into the dma-buf ». Utilise l'UAPI dma-buf standard, documentée pour
  l'interop explicite ↔ media.
- **Noyau** : patch « media: cedrus: wait for dma-buf read fences before
  writing capture buffers ». Petit, aligné sur le modèle explicite ; le RFC
  vb2 2026 (« opt-in dma_resv producer fences ») montre que le sujet est
  ouvert, mais notre variante est le côté consommateur.
- **Pas de nouvelle UAPI** : `DMA_BUF_IOCTL_IMPORT_SYNC_FILE` existe depuis
  plusieurs versions ; l'UAPI V4L2 in-fence de Padovan (2018) n'a jamais été
  fusionnée et n'est pas nécessaire.
- Divulgation IA obligatoire dans les cover letters.

## 11. Alternatives écartées

- **0006 (fence native + `NeedBuffer` poll)** : affiche l'image mais coûte
  30-44 % de `wa` ; remplacé par la présente spec.
- **N+1 (release-after-next-present)** : zéro fence, mais une frame de
  latence ; conservé comme repli si le fd natif n'est pas exportable.
- **Flip-event KMS** : sémantiquement propre, mais plus de plomberie pour un
  gain comparable au N+1.
- **Fencing explicite côté V4L2 (in-fence UAPI)** : non fusionné, inutile ici.
- **Vulkan** : PanVK expérimental/non conforme sur Mali-G31, pas de renderer
  Vulkan dans Kodi, et la synchronisation resterait à faire.
- **Plan DRM direct** : supprimerait la lecture GPU, mais hors périmètre.

## 12. Questions ouvertes et risques

- `eglDupNativeFenceFDANDROID` sur panfrost : le 0003 a déjà touché ce chemin
  et le 0006 prouve que la fence native signale ; le fd reste à valider en
  conditions réelles.
- Revue amont du patch cedrus : le sujet est discuté (RFC 2026), mais le patch
  est petit et défendable.
- Interaction avec `KODI_GBM_DISABLE_ASYNC_FENCE` : à mesurer avec et sans.
- Multi-plan / multi-dma-buf : couvert par la boucle sur `nb_objects`, non
  testé sur ce SoC.

## 13. Références

- `include/uapi/linux/dma-buf.h` — `dma_buf_import_sync_file`.
- `Documentation/driver-api/dma-buf.rst` — usages READ/WRITE, interop.
- `include/linux/dma-resv.h` — ordre KERNEL<WRITE<READ<BOOKKEEP.
- `include/media/videobuf2-core.h` — `struct vb2_plane.dbuf`.
- `drivers/staging/media/sunxi/cedrus/cedrus_video.c` — `vb2_dma_contig`,
  `v4l2_m2m`.
- Kodi `xbmc/utils/EGLFence.{h,cpp}` — `CreateGPUFence`, `FlushFence`.
- Kodi `RendererDRMPRIMEGLES.cpp` — `Render`, `NeedBuffer`.
- `docs/vp9-explicit-fencing.md` — étude détaillée.
