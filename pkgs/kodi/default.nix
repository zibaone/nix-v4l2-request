# Kodi 21.3 patché pour le décodeur stateless V4L2 Request (sunxi H616/H618).
#
# Quatre adaptations par rapport à `kodi-gbm` de nixpkgs :
#  - fenêtrage GBM (et non Wayland) : Kodi envoie sa requête plein écran avant
#    le mapping de sa surface (xbmc#20629, #27882) ; les compositeurs stricts
#    (wlroots, weston) l'ignorent et Kodi n'obtient jamais de taille valide —
#    il ne dessine alors rien. En GBM direct il n'y a pas de compositeur, donc
#    pas de négociation à rater ;
#  - `ffmpeg` remplacé par le paquet v4l2-request (voir ../ffmpeg-v4l2request) ;
#  - backport xbmc#25467 (mergée dans master, +29/−25) : `FindHWConfig()`
#    n'exige plus `device_type == AV_HWDEVICE_TYPE_DRM`, il accepte toute
#    hw config HW_DEVICE_CTX dont le pix_fmt est DRM_PRIME.
#  - défaut de `videoplayer.useprimedecoder` à true (0002) : sans lui
#    `CDVDVideoCodecDRMPRIME::Create()` renvoie nullptr et Kodi décode en CPU
#    sans le dire — le reste du paquet ne servirait à rien.
#  - garde `KODI_GBM_DISABLE_ASYNC_FENCE` (0003) : sur panfrost/H618, le chemin
#    « atomic asynchrone à fences EGL » d'amont fuit un descripteur par fence
#    non duplicable (mesuré : 986 en 40 min, table à 1 024 → EGL_BAD_DISPLAY
#    puis abandon). La variable force les commits bloquants, comme Kodi 20.
#  - délai de configuration du renderer porté à 30 s (0004) : sur H618, ouvrir
#    la fenêtre vidéo prend 3,5 à 13,5 s côté thread applicatif, alors que le
#    thread vidéo n'attendait que 1 s — écran noir avec le son en décodage
#    matériel, et première image retardée de 5 à 10 s en logiciel.
#
# Sur 21.3 + la série ffmpeg 6.0/6.1 (device_type = DRM) le comportement est
# identique SANS le patch 0001 ; il est là pour la variante ffmpeg 7+, où le
# device_type devient V4L2REQUEST (série LibreELEC master) — sans lui, Kodi
# 21.3 retomberait silencieusement sur le décodage CPU.
{
  lib,
  kodi-gbm,
  kodi-wayland,
  ffmpeg-v4l2request,
  sambaSupport ? false,
  # Système de fenêtrage : "gbm" (défaut, DRM direct, pas de compositeur) ou
  # "wayland" (client d'un compositeur). Un seul paquet, un seul jeu de
  # patches : le retour à cage ne rebase rien, il change cet argument.
  windowing ? "gbm",
}:
let
  base = if windowing == "wayland" then kodi-wayland else kodi-gbm;
in
(base.override {
  inherit sambaSupport;
  ffmpeg = ffmpeg-v4l2request;
}).overrideAttrs
  (old: {
    patches = (old.patches or [ ]) ++ [
      ./patches/0001-DVDVideoCodecDRMPRIME-v4l2request-hwdevice.patch
      ./patches/0002-linux-default-useprimedecoder.patch
      ./patches/0003-gbm-async-fence-disable-env.patch
      ./patches/0004-renderer-configure-timeout.patch
    ];

    # Le 0002 est un patch de données (system/settings/linux.xml) : s'il cesse
    # de s'appliquer, `patch` échoue déjà, mais s'il s'applique ailleurs que sur
    # le bon bloc il passerait inaperçu. On vérifie la valeur finale.
    postPatch = (old.postPatch or "") + ''
      grep -A5 'id="videoplayer.useprimedecoder"' system/settings/linux.xml \
        | grep -q '<default>true</default>' \
        || { echo "0002 : videoplayer.useprimedecoder n'est pas à true" >&2; exit 1; }

      # Le 0003 est une garde conditionnelle : s'il s'appliquait au mauvais
      # endroit, la compilation passerait sans que la variable soit jamais lue.
      grep -q 'std::getenv("KODI_GBM_DISABLE_ASYNC_FENCE")' \
        xbmc/windowing/gbm/WinSystemGbmEGLContext.cpp \
        || { echo "0003 : la garde KODI_GBM_DISABLE_ASYNC_FENCE est absente" >&2; exit 1; }

      # Le 0004 est un changement de constante : s'il s'appliquait au mauvais
      # Wait(), la compilation passerait et le correctif serait inerte.
      grep -A1 'm_stateEvent.Wait(30000ms)' \
        xbmc/cores/VideoPlayer/VideoRenderers/RenderManager.cpp >/dev/null \
        || { echo "0004 : le délai de configuration du renderer n'est pas à 30 s" >&2; exit 1; }
    '';

    # Élagage : bluez (télécommandes BT passent par le noyau/rc-core),
    # libplist (support iOS/USB → openssl ~6 Mo), lirc (les télécommandes
    # passent par rc-core/input, pas par le daemon lirc).
    buildInputs = builtins.filter (
      p:
      let
        n = lib.getName p;
      in
      n != "bluez" && n != "libplist" && n != "lirc"
    ) old.buildInputs;
  })
