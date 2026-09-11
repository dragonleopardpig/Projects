{
  lib,
  fetchzip,
  makeWrapper,
  python3,
  stdenvNoCC,
  source,
}:

let
  pythonEnvironment = python3.withPackages (
    pythonPackages: with pythonPackages; [
      ftfy
      numpy
      opencv-contrib-python
      paddleocr
      paddlepaddle
      pillow
      pypdfium2
      tokenizers
    ]
  );

  model = fetchzip {
    url = "https://paddle-model-ecology.bj.bcebos.com/paddlex/official_inference_model/paddle3.0.0/PP-FormulaNet_plus-L_infer.tar";
    hash = "sha256-h19i49d4APTPuJtsF8TqqU1Ktp4HkdOkqrL7Pq/akEA=";
    stripRoot = true;
  };
in
stdenvNoCC.mkDerivation {
  pname = "formulaocr-offline";
  version = "0.1.4";
  src = source;

  nativeBuildInputs = [ makeWrapper ];

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    install -Dm444 pix2tex/__init__.py \
      $out/lib/formulaocr-offline/pix2tex/__init__.py
    install -Dm444 pix2tex/offline_cli.py \
      $out/lib/formulaocr-offline/pix2tex/offline_cli.py
    install -Dm444 pix2tex/offline_ocr.py \
      $out/lib/formulaocr-offline/pix2tex/offline_ocr.py

    makeWrapper ${pythonEnvironment}/bin/python $out/bin/formulaocr-offline \
      --add-flags "-m pix2tex.offline_cli" \
      --prefix PYTHONPATH : "$out/lib/formulaocr-offline" \
      --set FORMULA_OCR_MODEL_DIR ${model} \
      --set PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK True \
      --set PYTHONNOUSERSITE 1

    runHook postInstall
  '';

  meta = {
    description = "Offline PP-FormulaNet image-to-LaTeX recognizer";
    homepage = "https://github.com/dragonleopardpig/LaTeX-OCR";
    license = with lib.licenses; [
      asl20
      mit
    ];
    mainProgram = "formulaocr-offline";
    platforms = lib.platforms.linux;
  };
}
