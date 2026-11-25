{
  description = "Kodi 21.3 + FFmpeg v4l2-request : hwaccel stateless V4L2 pour sunxi H616/H618";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/cd4ea8d57de16f4810bc5f14207bac45fbf19f67";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f (pkgsFor system));

      # Les optimisations de l'arbre kodi (overlays/v4l2-request.nix) sont
      # appliquées à la source : toutes les dépendances en bénéficient
      # (libdecor, cwiid, mesa-demos), pas seulement le paquet kodi.
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ self.overlays.default ];
        };

      # Paquets système élagués (pipewire, wlroots, v4l-utils, ffmpeg-headless)
      # — même instance que celle de l'image kiosque.
      kioskFor =
        system:
        import nixpkgs {
          inherit system;
          overlays = [
            self.overlays.default
            self.overlays.kiosk
          ];
        };

      mkPackages =
        pkgs:
        let
          ffmpeg = mkFFmpeg pkgs;
        in
        {
          ffmpeg-v4l2request = ffmpeg;
          kodi = pkgs.callPackage ./pkgs/kodi {
            ffmpeg-v4l2request = ffmpeg;
          };
          # Même Kodi, mêmes patches, fenêtrage Wayland : c'est le paquet à
          # consommer si l'on remet un compositeur devant le lecteur (voir
          # docs/fenetrage-kodi-gbm.md).
          kodi-wayland = pkgs.callPackage ./pkgs/kodi {
            ffmpeg-v4l2request = ffmpeg;
            windowing = "wayland";
          };
        };

      # Élagage des encodeurs : jamais utilisés en lecture (x265 ~24 Mo, x264,
      # libvpx, libaom, svt-av1 ~45 Mo au total). Le décodage reste intact,
      # AV1 compris (dav1d).
      mkFFmpeg =
        pkgs:
        pkgs.callPackage ./pkgs/ffmpeg-v4l2request {
          ffmpeg_6 = pkgs.ffmpeg_6.override {
            withX264 = false;
            withX265 = false;
            withVpx = false;
            withAom = false;
            withSvtav1 = false;
            withRav1e = false;
            # ffplay et la sortie SDL n'ont aucun usage dans une image kiosque.
            # Les laisser tire sdl2-compat → sdl3 → zenity → libadwaita → GTK4 :
            # c'est l'essentiel des 1,1 Gio de fermeture mesurés en CI pour un
            # lecteur qui n'existe pas.
            withSdl2 = false;
            buildFfplay = false;
          };
        };
    in
    {
      packages = nixpkgs.lib.genAttrs systems (
        system:
        let
          base = mkPackages (pkgsFor system);
        in
        base
        // {
          # Variante liée aux paquets *système* élagués. C'est elle que
          # l'image kiosque consomme : kodi partage alors sa pipewire avec le
          # système au lieu d'en embarquer une seconde copie (674 Mio de
          # fermeture, dont 149 Mio uniques à la variante non élaguée).
          kodi-kiosk = (mkPackages (kioskFor system)).kodi;
          # Variante élaguée de ffmpeg-headless, identique à celle que
          # l'image kiosque construit via kioskFor. Sans attribut explicite,
          # la CI la compile mais ne la pousse pas : le pin de la cible H96
          # laissait `hyh1lk7...` absent du cache.
          ffmpeg-headless-kiosk = (kioskFor system).ffmpeg-headless;
          # Même variante pour un kiosque à compositeur : ce que l'image
          # consommerait si l'on rebasculait sur cage.
          kodi-kiosk-wayland = (mkPackages (kioskFor system)).kodi-wayland;
          kodi-wayland = base.kodi-wayland;
          default = base.kodi;
        }
      );

      # Contrat hwaccel : h264 et hevc exposent DRM_PRIME / HW_DEVICE_CTX /
      # device_type DRM. C'est ce que FindHWConfig() de Kodi 21.3 exige.
      #
      # `kiosk-closure` n'est pas un test : c'est un prétexte pour que la CI
      # construise les paquets *système* élagués (mesa, pipewire,
      # wireplumber, v4l-utils, ffmpeg-headless). Sans lui, la CI ne voit
      # jamais ces dérivations, le cache ne les contient pas, et l'assemblage
      # d'image les recompile sous émulation — 1 h 30 pour un mesa.
      #
      # `cage` et `wlroots` en sont sortis avec le passage du kiosque en GBM
      # direct (docs/fenetrage-kodi-gbm.md) : aucune fermeture d'image ne les
      # contient plus, les y laisser n'entretenait qu'un cache pour une
      # architecture abandonnée.
      checks = nixpkgs.lib.genAttrs systems (
        system:
        let
          kiosk = kioskFor system;
          pkgs = pkgsFor system;
        in
        {
          hwconfig = self.packages.${system}.ffmpeg-v4l2request.passthru.tests.hwconfigTest;
          kiosk-closure = kiosk.buildEnv {
            name = "kiosk-closure";
            paths = with kiosk; [
              mesa
              pipewire
              wireplumber
              v4l-utils
              ffmpeg-headless
            ];
          };

          # Les variantes Wayland ne sont pas compilées par la CI (elles
          # doubleraient le build de Kodi), mais leur évaluation est vérifiée :
          # une variante de repli qui n'évalue plus ne se découvrirait qu'au
          # moment précis où l'on en a besoin.
          kodi-wayland-eval = pkgs.runCommand "check-kodi-wayland-eval" { } ''
            echo ${self.packages.${system}.kodi-wayland.drvPath} > $out
            echo ${self.packages.${system}.kodi-kiosk-wayland.drvPath} >> $out
          '';

          # Formatage : `nix flake check` devient le seul gate à retenir.
          # `self` plutôt que `./.` pour que le chemin soit celui du dépôt
          # évalué, pas du répertoire courant.
          formatting = pkgs.runCommand "check-nixfmt" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
            nixfmt --check ${self}/flake.nix ${self}/overlays/*.nix ${self}/pkgs/*/default.nix
            touch $out
          '';
        }
      );

      # Réutilisable par un flake NixOS : mêmes paquets, mêmes optimisations,
      # sans dupliquer les définitions.
      overlays.default = import ./overlays/v4l2-request.nix;

      # Niveau 2, opt-in : élagage des paquets *système* du profil kiosque
      # (pipewire, wlroots, v4l-utils, ffmpeg-headless). Séparé parce que ça
      # change le comportement d'un système, pas seulement l'arbre de kodi.
      overlays.kiosk = import ./overlays/kiosk.nix;

      formatter = forAll (pkgs: pkgs.nixfmt);
    };
}
