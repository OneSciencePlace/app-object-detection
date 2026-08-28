#!/usr/bin/env python3
"""
run.py - Object detection demo for a Tapis App container.

Reads an input image, runs a pretrained YOLO11 model over it, and writes:
  - <stem>_detected.jpg   : the image with bounding boxes + labels drawn
  - detections.json       : structured list of {class, confidence, bbox}

Designed to be called as the container ENTRYPOINT from a Tapis batch app.
Inputs/outputs are relative to the current working directory, which Tapis
sets to the job's staged working directory - no hardcoded paths.

Usage:
    python run.py --image photo.jpg
    python run.py --image photo.jpg --output-dir results --conf 0.4
"""

import argparse
import json
import os
import sys
from pathlib import Path


def parse_args():
    p = argparse.ArgumentParser(description="Run object detection on an image.")
    p.add_argument("--image", required=True, help="Path to input image (staged by Tapis fileInputs).")
    p.add_argument("--output-dir", default=".", help="Where to write outputs (default: job working dir).")
    p.add_argument("--model", default=os.environ.get("APP_MODEL", "/app/yolo11n.pt"),
                   help="Ultralytics model name or path (default: the weights baked into the image).")
    p.add_argument("--conf", type=float, default=0.25, help="Confidence threshold (default: 0.25).")
    return p.parse_args()


def main():
    args = parse_args()

    image_path = Path(args.image)
    if not image_path.is_file():
        print(f"ERROR: input image not found: {image_path}", file=sys.stderr)
        sys.exit(1)

    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    # Imported here so --help works fast even before torch/ultralytics load.
    from ultralytics import YOLO

    print(f"Loading model: {args.model}")
    model = YOLO(args.model)

    print(f"Running inference on: {image_path} (conf={args.conf})")
    results = model.predict(source=str(image_path), conf=args.conf, verbose=False)
    result = results[0]

    # 1. Annotated image
    annotated = result.plot()  # numpy array (BGR) with boxes/labels drawn
    out_image_path = out_dir / f"{image_path.stem}_detected.jpg"
    import cv2  # comes in with ultralytics/opencv-python-headless
    cv2.imwrite(str(out_image_path), annotated)
    print(f"Wrote annotated image: {out_image_path}")

    # 2. Structured detections
    detections = []
    for box in result.boxes:
        cls_id = int(box.cls[0])
        detections.append({
            "class": result.names[cls_id],
            "confidence": round(float(box.conf[0]), 4),
            "bbox_xyxy": [round(v, 1) for v in box.xyxy[0].tolist()],
        })

    out_json_path = out_dir / "detections.json"
    with open(out_json_path, "w") as f:
        json.dump({"image": image_path.name, "count": len(detections), "detections": detections}, f, indent=2)
    print(f"Wrote detections: {out_json_path}")

    # Human-readable summary for the Tapis job log / tutorial audience
    if detections:
        print(f"\nFound {len(detections)} object(s):")
        for d in detections:
            print(f"  - {d['class']} ({d['confidence']:.0%})")
    else:
        print("\nNo objects detected above the confidence threshold.")


if __name__ == "__main__":
    main()
