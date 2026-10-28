# ffmpeg-v4l2request — FFmpeg 6.1 + hwaccel stateless V4L2 Request API.
#
# Pourquoi ce paquet : nixpkgs n'expose que `withV4l2` (libv4l2) et
# `withV4l2M2m` (`--enable-v4l2-m2m`, API *stateful*). Le décodeur stateless du
# H616/H618 (driver `cedrus`) et des SoC Rockchip passe par la Request API, dont
# le support n'existe qu'en aval — d'où le jeu LibreELEC `v4l2-request`
# vendorisé ici (voir l'en-tête du patch pour la provenance et les adaptations
# 6.0 → 6.1).
#
# Le paquet dérive de `ffmpeg_6` (6.1.6) et non d'FFmpeg 7 : Kodi 21.3 lie la
# soname libavcodec 60. Le jeu fournit les hwaccels sous le contrat
# HW_CONFIG_HWACCEL(1,0,0, DRM_PRIME, DRM) — pix_fmt AV_PIX_FMT_DRM_PRIME,
# méthode HW_DEVICE_CTX, device_type DRM — exactement ce que
# FindHWConfig() de Kodi 21.3 accepte.
#
# Consommation (profil kodi-standalone) :
#   ffmpeg_6 = pkgs.callPackage ../../pkgs/ffmpeg-v4l2request { };
#   (l'élagage x264/x265/vpx/aom reste appliqué sur le paquet retourné)
#
# Gates :
#   nix build .#ffmpeg-v4l2request
#   nix build .#checks.x86_64-linux.ffmpeg-v4l2request   (test C du contrat)
#   ffmpeg -buildconf | grep -- --enable-v4l2-request
{
  lib,
  stdenv,
  ffmpeg_6,
  pkg-config,
  runCommandLocal,
  udev,
  libdrm,
}:

let
  # `--enable-v4l2-request` n'est pas dans le configure amont : il vient du
  # patch. `--enable-libudev` est requis par la RCU (deps
  # `v4l2_request_deps="… libdrm libudev"`) et n'est pas câblé par generic.nix.
  patched = ffmpeg_6.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      ./patches/0001-v4l2-request-ffmpeg-6.1.6.patch
      # 0002 : capture multi-plan (NV12M). Requis par meson-amvdec (Amlogic
      # GXL/GXM), qui n'expose que NV12M en capture ; 0001 ne négocie que des
      # formats mono-plan et échoue donc à `select capture format failed`.
      # Additif : les formats mono-plan (NV12, sunxi tiled, P010, AFBC) sont
      # inchangés.
      ./patches/0002-v4l2-request-nv12m-capture.patch
      # 0003 : sonde VP9. `v4l2_request_vp9_init()` appelle `fill_frame()` alors
      # qu'aucun en-tête n'a encore été analysé : le descripteur envoyé au probe
      # a `bit_depth` nul, pas de drapeau de sous-échantillonnage et des
      # dimensions à -1. Le `try_ctrl` du driver `meson-amvdec` le rejette par
      # EINVAL, et ffmpeg conclut « No V4L2 media device found for VP9F » alors
      # que le matériel est capable. On sonde avec un descripteur de référence
      # valide (profil 0, 8 bits, 4:2:0) ; les contrôles par image portent les
      # paramètres réels.
      ./patches/0003-v4l2-request-vp9-probe-descriptor.patch
      # 0004 : capacité de tranches HEVC. `meson-amvdec` annonce
      # AMVDEC_HEVC_MAX_SLICES = 800 pour SLICE_PARAMS, alors que cette série
      # code en dur MAX_SLICES 600 et refuse l'initialisation (« unsupported
      # max slices, 800 ») avant la moindre image. Aligner l'array sur la
      # capacité réelle du driver.
      ./patches/0004-v4l2-request-hevc-max-slices.patch
    ];

    configureFlags = (old.configureFlags or [ ]) ++ [
      "--enable-v4l2-request"
      "--enable-libudev"
    ];

    buildInputs = (old.buildInputs or [ ]) ++ [
      udev
      libdrm
    ];
  });

  # Test exécuté (x86_64, natif) : interroge avcodec_get_hw_config et exige le
  # contrat de Kodi 21.3 pour h264 et hevc. `ffmpeg -hwaccels` ne peut pas
  # servir de gate ici : il liste les AVHWDeviceType et le type V4L2REQUEST
  # n'existe que dans la série LibreELEC master (FFmpeg 7+).
  hwconfigTest =
    runCommandLocal "ffmpeg-v4l2request-hwconfig"
      {
        nativeBuildInputs = [ pkg-config ];
        buildInputs = [ patched ];
      }
      ''
        ${stdenv.cc}/bin/cc -Wall -Wextra -Werror -O2 \
          ${./test-hwconfig.c} -o check \
          $(pkg-config --cflags --libs libavcodec libavutil)
        ./check | tee "$out"
      '';
in
patched.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    tests = (old.passthru.tests or { }) // {
      inherit hwconfigTest;
    };
  };
})
