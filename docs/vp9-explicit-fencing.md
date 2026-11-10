# Fencing explicite VPU↔GPU pour DRMPRIME — étude (approche #6)

> Note de conception — nix-v4l2-request — 2026-11-10.
> Objet : supprimer le compromis « fence EGL qui ne signale pas » / « fence native qui
> bloque » en faisant porter la synchronisation par le noyau, via les dma-buf.
> Voir aussi : la spec `docs/specs/drmprime-explicit-fencing.md` ; notes
> internes nixbian (plan média H616/H618, rapport P0 VP9, inventaire codecs).

## 1. Objectif

Sur le chemin VP9 cedrus → DRM PRIME → renderer GLES de Kodi, il n'existe
**aucun fencing implicite entre le VPU et le GPU**. Le buffer NV12 produit par
cedrus est exporté en dma-buf, importé par panfrost comme texture, puis réutilisé
par le VPU au frame suivant. Rien dans le noyau n'empêche le VPU d'écraser le
buffer pendant que le GPU le lit encore.

Kodi compense avec une fence EGL dans le renderer. Sur panfrost, cette fence
n'est pas fiable : `EGL_SYNC_FENCE_KHR` ne signale pas (47 timeouts/300 frames),
et la variante native (`EGL_SYNC_NATIVE_FENCE_ANDROID`) signale mais coûte 30-44 %
de `wa` (attente GPU dans le chemin chaud). Les deux extrêmes sont mauvais.

L'objectif est donc : **le VPU attend la fin de lecture GPU dans le noyau,
sans polling userspace, sans frame de latence supplémentaire.**

## 2. Le modèle dma-buf et les primitives disponibles

Le noyau fournit déjà tout ce qu'il faut côté UAPI :

- `struct dma_resv` : ensemble de fences attachées à un `dma_buf`
  (`dmabuf->resv`), avec des usages `KERNEL < WRITE < READ < BOOKKEEP`.
  Une requête `DMA_RESV_USAGE_READ` renvoie aussi les fences `WRITE` et
  `KERNEL` (commentaire de `include/linux/dma-resv.h`) — donc **toutes** les
  fences de synchronisation implicite.
- `sync_file` : fence exportable en fd (`sync_file_create`,
  `sync_file_get_fence`).
- `DMA_BUF_IOCTL_IMPORT_SYNC_FILE` / `DMA_BUF_IOCTL_EXPORT_SYNC_FILE`
  (`include/uapi/linux/dma-buf.h`, `CONFIG_SYNC_FILE`) : insertion d'un
  `sync_file` dans le `dma_resv` d'un dma-buf, avec l'usage READ ou WRITE.
  La documentation est explicite : ces ioctls servent à faire interopérer un
  producteur explicite (Vulkan, GL) avec « most media drivers/video » qui
  attendent de la synchronisation implicite. C'est exactement notre cas.

Côté V4L2, l'UAPI « in-fence » (`V4L2_BUF_FLAG_IN_FENCE`, `fence_fd`) a été
proposée par Gustavo Padovan (v8, 2018) mais **n'a jamais été fusionnée**. Un
RFC de 2026 (`media: videobuf2: opt-in dma_resv producer fences`) rouvre le
sujet, mais pour la direction inverse (producteur V4L2 → consommateur). On n'a
donc **pas besoin de nouvelle UAPI** : `IMPORT_SYNC_FILE` suffit côté
userspace, et le noyau doit simplement honorer le `dma_resv` avant d'écrire.

## 3. Architecture proposée

```
frame N :
  cedrus (VPU) écrit NV12 dans le buffer B (capture vb2, exporté dma-buf)
  ├─ VPU signale la fin d'écriture (déjà géré par vb2/irq)
  ▼
  ffmpeg récupère B en DRM PRIME, Kodi l'importe comme texture EGL
  ▼
  Kodi : draw GLES qui lit B
  ├─ CEGLFence::CreateGPUFence()      (native fence, après le draw)
  ├─ fd = CEGLFence::FlushFence()      (eglDupNativeFenceFDANDROID)
  ├─ ioctl(B.fd, DMA_BUF_IOCTL_IMPORT_SYNC_FILE, {READ, fd})
  └─ close(fd)
  ▼
  NeedBuffer(B) → true : Kodi rend B au décodeur
  ▼
frame N+1 :
  ffmpeg re-queue B dans la capture V4L2
  ▼
  cedrus, avant de programmer le VPU :
  └─ dma_resv_wait_timeout(B.resv, DMA_RESV_USAGE_READ, ...)
       → attend la fence READ du GPU (celle importée)
       → le VPU n'écrase B qu'une fois le GPU lecteur terminé
```

Propriétés :

- **zéro fence dans le chemin chaud Kodi** : plus de `IsSignaled()` par frame ;
- **zéro frame de latence** : le VPU démarre dès que le GPU a fini, pas au
  frame suivant ;
- **attente par interruption** dans le noyau (`dma_resv_wait_timeout`), pas de
  polling ;
- **sémantique correcte** : la fence importée couvre le draw qui a lu B
  (native fence créée juste après les commandes GL) ; le `dma_resv` est
  partagé entre l'export vb2 et l'import panfrost.

## 4. Patch Kodi (userspace)

Fichier : `xbmc/cores/VideoPlayer/VideoRenderers/HwDecRender/RendererDRMPRIMEGLES.cpp`.

Le matériel existe déjà dans `CEGLFence` (`xbmc/utils/EGLFence.cpp`) :

- `CreateGPUFence()` crée une fence native (`EGL_SYNC_NATIVE_FENCE_ANDROID`,
  sans fd) ;
- `FlushFence()` renvoie le fd (`eglDupNativeFenceFDANDROID`) et détruit
  l'EGL sync — le fd porte la fence.

Dans `CRendererDRMPRIMEGLES::Render`, juste après
`buf.fence->DestroyFence(); buf.fence->CreateFence();` (ligne ~392) :

```
buf.fence->CreateGPUFence();
int fd = buf.fence->FlushFence();
if (fd >= 0 && buf.videoBuffer)
{
  auto* desc = buf.videoBuffer->GetDescriptor();   // AVDRMFrameDescriptor
  for (int i = 0; i < desc->nb_objects; i++)
  {
    struct dma_buf_import_sync_file arg = { DMA_BUF_SYNC_READ, fd };
    ioctl(desc->objects[i].fd, DMA_BUF_IOCTL_IMPORT_SYNC_FILE, &arg);
  }
  close(fd);
}
```

Puis `NeedBuffer` (ligne 165) devient :

```
bool CRendererDRMPRIMEGLES::NeedBuffer(int index)
{
  return true;   // le noyau garantit l'ordre VPU/GPU via le dma_resv
}
```

Le fd du dma-buf est déjà dans `AVDRMFrameDescriptor` (`objects[i].fd`) ; il
n'y a pas de nouvelle structure à exposer.

Garde-fous :

- si `FlushFence()` échoue (panfrost ne sait pas exporter le fd), on retombe
  sur le comportement actuel (fence EGL) ou sur le N+1 ;
- ne pas importer deux fois la même fence pour le même buffer ;
- fermer le fd après l'ioctl : `IMPORT_SYNC_FILE` prend une référence sur la
  fence, le fd n'est plus nécessaire.

## 5. Patch noyau (cedrus)

Fichier : `drivers/staging/media/sunxi/cedrus/cedrus_dec.c` (ou
`cedrus_video.c`), dans le chemin du job m2m (`cedrus_device_run`), avant de
programmer le VPU :

```
struct vb2_v4l2_buffer *dst = v4l2_m2m_next_dst_buf(ctx->fh.m2m_ctx);
struct dma_buf *dbuf = dst->vb2_buf.planes[0].dbuf;   // NULL si non exporté
if (dbuf)
{
  long ret = dma_resv_wait_timeout(dbuf->resv, DMA_RESV_USAGE_READ,
                                   true, msecs_to_jiffies(500));
  if (ret == 0)
    dev_warn(dev->dev, "timeout waiting for GPU read fence\n");
  else if (ret < 0)
    /* -ERESTARTSYS : job annulé, laisser le m2m gérer */;
}
```

Points vérifiés dans le code réel :

- `struct vb2_plane` contient `struct dma_buf *dbuf` (videobuf2-core.h) ;
  il est renseigné par `VIDIOC_EXPBUF`, ce que fait ffmpeg pour DRMPRIME.
- cedrus utilise `vb2_dma_contig_memops` et `v4l2_m2m` ; le buffer capture est
  un `vb2_v4l2_buffer` dont `.vb2_buf.planes[0].dbuf` est le dma-buf exporté.
- `cedrus_device_run` tourne dans le kthread m2m, donc peut dormir.
- `dma_resv_wait_timeout(..., DMA_RESV_USAGE_READ, ...)` attend KERNEL+WRITE+READ
  (cf. commentaire de `dma-resv.h`) : c'est l'ensemble des fences implicites,
  dont la fence READ importée par Kodi.

Pourquoi pas dans `cedrus_buf_queue` : ce callback est appelé depuis l'ioctl
QBUF ; y dormir bloquerait l'appelant. Le job m2m est le bon contexte.

Pourquoi pas dans vb2-core : un helper générique serait plus propre en amont,
mais change la sémantique de qbuf pour tous les drivers. Le patch cedrus est
minimal et testable ; une version générique pourra suivre.

## 6. Sémantique et sûreté

- La native fence est créée **après** les commandes GL du draw ; elle couvre
  donc la lecture de B par le GPU.
- `DMA_BUF_IOCTL_IMPORT_SYNC_FILE` avec `DMA_BUF_SYNC_READ` ajoute la fence
  avec `DMA_RESV_USAGE_READ` (vérifié dans `drivers/dma-buf/dma-buf.c`).
- Le `dma_resv` est le même objet pour l'export vb2 et l'import panfrost :
  `vb2_plane.dbuf` et le fd de Kodi pointent le même `dma_buf`.
- Le VPU attend avant d'écrire ; le GPU n'est jamais lu pendant une écriture.
- `NeedBuffer=true` ne crée pas de course : le renderer ne réutilise pas B pour
  rendre, il le rend au décodeur, et le noyau bloque le décodeur tant que le
  GPU lit.

## 7. Cas limites

1. **Buffer non exporté** (`dbuf == NULL`) : pas d'attente, comportement
   actuel. Ne concerne pas le chemin DRMPRIME.
2. **Aucune fence dans le resv** : `dma_resv_wait_timeout` rend immédiatement.
3. **Fence qui ne signale jamais** : timeout 500 ms, warning, on continue
   (dégradation contrôlée, pas de blocage du décodeur).
4. **`FlushFence()` échoue** : fallback EGL/N+1, à instrumenter.
5. **Plusieurs plans** : cedrus n'en a qu'un ; la boucle sur `nb_objects`
   couvre les cas multi-dma-buf.
6. **Import en double** : à éviter (compter les imports par buffer, ou ne le
   faire qu'une fois par frame).
7. **Fin de stream / flush** : les fences en attente sont libérées avec les
   buffers ; `dma_resv` gère les fences non signalées à la destruction.

## 8. Coût, effort, risques

| Élément | Estimation |
|---|---|
| Patch Kodi | ~50 lignes, 1 jour avec tests |
| Patch cedrus | ~40 lignes, 1 jour avec tests |
| Build/test | 2 builds Kodi + 1 noyau, ~2 h de machine |
| Total | 2-4 jours |
| Risque principal | `eglDupNativeFenceFDANDROID` sur panfrost (le 0003 a déjà touché ce chemin ; le 0006 prouve que la fence native signale) |
| Risque secondaire | revue amont du patch cedrus (le RFC 2026 montre que le sujet est discuté) |

Performance attendue : `wa` proche de 0 (le VPU attend par IRQ, pas en poll),
`timeout waiting` = 0, fps 29-30, menus fluides.

## 9. Stratégie amont

Deux patchs indépendants :

1. **Kodi** : « RendererDRMPRIMEGLES: import the GPU read fence into the
   dma-buf ». Utilise l'UAPI dma-buf standard, documentée pour cet usage.
   Auto-suffisant, testable, sans dépendance noyau.
2. **cedrus** : « media: cedrus: wait for dma-buf read fences before writing
   capture buffers ». Petit, aligné sur le modèle explicite (la fence vient de
   userspace via l'UAPI dma-buf), et sur le RFC vb2 2026.

La doc noyau cite explicitement l'interop « explicit API ↔ media drivers/
video » comme cas d'usage de `IMPORT_SYNC_FILE` : c'est l'argument d'amont.

## 10. Plan de test

1. Build noyau + Kodi avec les deux patchs, déploiement `boot`.
2. Lecture du sample VP9 1080p : `timeout waiting` = 0, image, IRQ +300.
3. `vmstat 2 10` : `wa` < 5 %, `bi`/`bo` faibles.
4. Menus : navigation fluide pendant la lecture.
5. Vérification du resv : `/sys/kernel/debug/dma_buf/bufinfo` doit montrer une
   fence panfrost sur le buffer ; sinon `ftrace`/`dma_fence` events.
6. A/B : 0006 (lag) vs sans 0006 (pas d'image) vs #6.
7. Non-régressions H264/HEVC/VP8/MPEG2 (le chemin de release change pour tous
   les codecs DRMPRIME).

## 11. Replis

- Si le fd natif n'est pas exportable : **N+1** (release-after-next-present),
  zéro fence, une frame de latence.
- Si le patch cedrus est refusé en amont : garder le patch local + le N+1 en
  amont.
- Si le VPU attend trop (fence jamais signalée) : timeout + fallback N+1.

## 12. Références

- `include/uapi/linux/dma-buf.h` : `DMA_BUF_IOCTL_IMPORT_SYNC_FILE`,
  `DMA_BUF_IOCTL_EXPORT_SYNC_FILE`.
- `Documentation/driver-api/dma-buf.rst` : sémantique des usages READ/WRITE et
  interop explicite ↔ implicite.
- `include/linux/dma-resv.h` : ordre KERNEL<WRITE<READ<BOOKKEEP et requêtes.
- `include/media/videobuf2-core.h` : `struct vb2_plane.dbuf`.
- `drivers/staging/media/sunxi/cedrus/cedrus_video.c` : `vb2_dma_contig_memops`,
  `v4l2_m2m`.
- Kodi `xbmc/utils/EGLFence.{h,cpp}` : `CreateGPUFence`, `FlushFence`.
- Kodi `RendererDRMPRIMEGLES.cpp` : `Render` (ligne ~392), `NeedBuffer`
  (ligne ~165).
- linux-media : RFC « videobuf2: opt-in dma_resv producer fences » (avril 2026) ;
  patchset « V4L2 Explicit Synchronization » (Padovan, v8, 2018, non fusionné).
