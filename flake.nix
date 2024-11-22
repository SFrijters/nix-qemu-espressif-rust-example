{
  description = "Running Rust code for ESP32C3 on a QEMU emulator";
  inputs = {
    qemu-espressif.url = "github:SFrijters/nix-qemu-espressif";
    nixpkgs.follows = "qemu-espressif/nixpkgs";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "qemu-espressif/nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      qemu-espressif,
      rust-overlay,
      ...
    }:
    let
     forAllSystems =
        function:
        nixpkgs.lib.genAttrs [
          # Maybe other systems work as well, but they have not been tested
          "x86_64-linux"
          "aarch64-linux"
        ] (system: function (import nixpkgs {
            inherit system;
            overlays = [ (import rust-overlay) ];
        }));
    in

          pkgsCross = import nixpkgs {
            system = pkgs.system;
            crossSystem = {
              # https://github.com/NixOS/nixpkgs/issues/281527#issuecomment-2180971963
              inherit system;
              rust.rustcTarget = "riscv32imc-unknown-none-elf";
            };
          };

          toolchain = (pkgs.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml);

          rustPlatform = pkgsCross.makeRustPlatform {
            rustc = toolchain;
            cargo = toolchain;
          };

          elf-binary = pkgs.callPackage ./blinky { inherit rustPlatform; };

          inherit (elf-binary.meta) name;

          emulate-script = pkgs.writeShellApplication {
            name = "emulate-${name}";
            runtimeInputs = [
              pkgs.espflash
              pkgs.esptool
              pkgs.gnugrep
              pkgs.netcat
              qemu-esp32c3
            ];
            text = ''
              # Some sanity checks
              file -b "${elf-binary}/bin/${name}" | grep "ELF 32-bit LSB executable.*UCB RISC-V.*soft-float ABI.*statically linked"
              # Create an image for qemu
              espflash save-image --chip esp32c3 --merge ${elf-binary}/bin/${name} ${name}.bin
              # Get stats
              esptool.py image_info --version 2 ${name}.bin
              # Start qemu in the background, open a tcp port to interact with it
              qemu-system-riscv32 -nographic -monitor tcp:127.0.0.1:55555,server,nowait -icount 3 -machine esp32c3 -drive file=${name}.bin,if=mtd,format=raw -serial file:qemu-${name}.log &
              # Wait a bit
              sleep 3s
              # Kill qemu nicely by sending 'q' (quit) over tcp
              echo q | nc -N 127.0.0.1 55555
              cat qemu-${name}.log
              # Sanity check
              grep "ESP-ROM:esp32c3-api1-20210207" qemu-${name}.log
              # Did we get the expected output?
              grep "Hello world" qemu-${name}.log
            '';
          };

          flash-script = pkgs.writeShellApplication {
            name = "flash-${name}";
            runtimeInputs = [ pkgs.espflash ];
            text = ''
              espflash flash --monitor ${elf-binary}/bin/${name}
            '';
          };

        in
        {
          packages = forAllSystems (pkgs: rec {
            default = emulate-script;
            inherit elf-binary flash-script emulate-script;
            qemu-esp32c3 = qemu-espressif.packages.${pkgs.system}.qemu-esp32c3;
          });

          checks = forAllSystems (pkgs: {
            default = pkgs.runCommand "qemu-check-${name}" { } ''
              ${lib.getExe self.packages.emulate-script}
              mkdir "$out"
              cp qemu-${name}.log "$out"
            ''});

          devShells = forAllSystems (pkgs: {
            default = pkgs.mkShell {
              name = "${name}-dev";

              packages = [
                pkgs.espflash
                pkgs.esptool
                pkgs.gnugrep
                pkgs.netcat
                self.qemu-esp32c3
                self.toolchain
              ];

              shellHook = ''
                echo "==> Using toolchain version ${toolchain.version}"
                echo "    Using cargo version $(cargo --version)"
                echo "    Using rustc version $(rustc --version)"
                echo "    Using espflash version $(espflash --version)"
              '';
            }}
          );

          apps = forAllSystems (pkgs: rec {
            default = emulate;
            emulate = {
              type = "app";
              program = "${lib.getExe self.packages.emulate-script}";
            };

            flash = {
              type = "app";
              program = "${lib.getExe self.packages.flash-script}";
            };
          });

          formatter = forAllSystems (pkgs: pkgs.nixfmt-rfc-style);
        }
      );
}
