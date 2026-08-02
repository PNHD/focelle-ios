#!/usr/bin/env python3
"""Deterministic generator for Focelle's owned-synthetic pose template bundle.

Run from the repository root:
    python scripts/generate_pose_templates.py

It rewrites Focelle/Coach/PoseTemplates.json. The output is deterministic:
same input seeds + parameters always produce byte-identical JSON, so the
generated bundle can be reviewed and re-verified in CI.

Validation and deduplication rules mirror Focelle/Coach/PoseTemplate.swift.
"""

from __future__ import annotations

import json
import math
import pathlib
import sys

SCHEMA_VERSION = 1
SOURCE = "owned-synthetic"
CATEGORIES = {"onePerson", "couple", "smallGroup", "product", "food", "scenery"}
PERSON_CATEGORIES = {"onePerson", "couple", "smallGroup"}
CROP_SAFETY_MARGIN = 0.05
MIN_COUNT = 72
MAX_COUNT = 96
DISTANCE_THRESHOLD = 0.02

ALL_LANDMARKS = [
    "head_top", "nose",
    "left_shoulder", "right_shoulder", "left_elbow", "right_elbow",
    "left_hand", "right_hand", "left_hip", "right_hip",
    "left_knee", "right_knee", "left_ankle", "right_ankle",
    "left_foot", "right_foot",
]


def p(x: float, y: float) -> dict:
    return {"x": round(x, 4), "y": round(y, 4)}


def person(
    shoulder_y: float = 0.72,
    hip_y: float = 0.55,
    knee_y: float = 0.38,
    foot_y: float = 0.14,
    center_x: float = 0.5,
    lean: float = 0.0,
    seated: bool = False,
) -> dict:
    """Canonical human skeleton with plausible joint angles."""
    if seated:
        knee_y = 0.50
        foot_y = 0.28
    head_y = min(shoulder_y + 0.24, 0.98)
    hand_y = hip_y if seated else 0.62
    elbow_y = shoulder_y - 0.02 if seated else shoulder_y - 0.05
    return {
        "head_top": p(center_x + lean, min(head_y + 0.08, 1.0)),
        "nose": p(center_x + lean, head_y),
        "left_shoulder": p(center_x - 0.11 + lean, shoulder_y),
        "right_shoulder": p(center_x + 0.11 + lean, shoulder_y),
        "left_elbow": p(center_x - 0.18 + lean, elbow_y),
        "right_elbow": p(center_x + 0.18 + lean, elbow_y),
        "left_hand": p(center_x - 0.15 + lean, hand_y),
        "right_hand": p(center_x + 0.15 + lean, hand_y),
        "left_hip": p(center_x - 0.08 + lean, hip_y),
        "right_hip": p(center_x + 0.08 + lean, hip_y),
        "left_knee": p(center_x - 0.09 + lean, knee_y),
        "right_knee": p(center_x + 0.09 + lean, knee_y),
        "left_ankle": p(center_x - 0.06 + lean, foot_y),
        "right_ankle": p(center_x + 0.06 + lean, foot_y),
        "left_foot": p(center_x - 0.07 + lean, foot_y - 0.03),
        "right_foot": p(center_x + 0.07 + lean, foot_y - 0.03),
    }


def couple(center_x: float = 0.5, seated: bool = False, offset: float = 0.14) -> dict:
    left = person(center_x=center_x - offset, seated=seated)
    right = person(center_x=center_x + offset, seated=seated)
    return {**left, **{f"subject2_{k}": v for k, v in right.items()}}


SEEDS = [
    {
        "id": "one-full-front",
        "category": "onePerson", "framing": "full", "orientation": "front",
        "subjectCount": 1, "cameraHints": ["eyeLevel"],
        "landmarks": person(center_x=0.50),
        "subjectWidth": 0.34, "subjectHeight": 0.82, "centerX": 0.50, "centerY": 0.48,
        "headroom": 0.12, "faceZone": (0.40, 0.78, 0.20, 0.16),
        "zoom": 1.0, "tags": ["portrait", "fullBody"], "light": (0.25, 0.90, False),
        "vi": "Đứng thẳng, giữ khoảng cách để toàn thân vừa khung.", "en": "Stand straight and keep full body in frame.",
    },
    {
        "id": "one-medium-front",
        "category": "onePerson", "framing": "medium", "orientation": "front",
        "subjectCount": 1, "cameraHints": ["eyeLevel"],
        "landmarks": person(shoulder_y=0.62, hip_y=0.48, knee_y=0.30, foot_y=0.10, center_x=0.50),
        "subjectWidth": 0.44, "subjectHeight": 0.70, "centerX": 0.50, "centerY": 0.44,
        "headroom": 0.16, "faceZone": (0.36, 0.74, 0.28, 0.18),
        "zoom": 1.3, "tags": ["portrait"], "light": (0.25, 0.90, False),
        "vi": "Tiến lại gần, cắt ngang hông.", "en": "Move closer, crop at the hips.",
    },
    {
        "id": "one-threequarter",
        "category": "onePerson", "framing": "full", "orientation": "threeQuarter",
        "subjectCount": 1, "cameraHints": ["eyeLevel"],
        "landmarks": person(center_x=0.52, lean=0.03),
        "subjectWidth": 0.32, "subjectHeight": 0.80, "centerX": 0.52, "centerY": 0.48,
        "headroom": 0.12, "faceZone": (0.42, 0.78, 0.20, 0.16),
        "zoom": 1.0, "tags": ["portrait", "fullBody"], "light": (0.25, 0.90, False),
        "vi": "Xoay nhẹ 3/4 người về phía máy.", "en": "Turn three quarters toward the camera.",
    },
    {
        "id": "one-seated",
        "category": "onePerson", "framing": "medium", "orientation": "front",
        "subjectCount": 1, "cameraHints": ["eyeLevel"],
        "landmarks": person(seated=True, center_x=0.50),
        "subjectWidth": 0.42, "subjectHeight": 0.62, "centerX": 0.50, "centerY": 0.55,
        "headroom": 0.14, "faceZone": (0.38, 0.76, 0.24, 0.16),
        "zoom": 1.2, "tags": ["portrait", "seated"], "light": (0.25, 0.90, False),
        "vi": "Ngồi thẳng lưng, mắt ngang máy.", "en": "Sit up straight with eyes level with the camera.",
    },
    {
        "id": "one-side",
        "category": "onePerson", "framing": "full", "orientation": "side",
        "subjectCount": 1, "cameraHints": ["eyeLevel"],
        "landmarks": person(center_x=0.50, lean=0.06),
        "subjectWidth": 0.28, "subjectHeight": 0.82, "centerX": 0.50, "centerY": 0.48,
        "headroom": 0.12, "faceZone": (0.42, 0.79, 0.16, 0.15),
        "zoom": 1.0, "tags": ["portrait", "profile"], "light": (0.25, 0.90, False),
        "vi": "Nghiêng người nhẹ, nhìn về phía máy.", "en": "Lean slightly and look toward the camera.",
    },
    {
        "id": "one-close-portrait",
        "category": "onePerson", "framing": "close", "orientation": "front",
        "subjectCount": 1, "cameraHints": ["eyeLevel"],
        "landmarks": person(shoulder_y=0.48, hip_y=0.36, knee_y=0.22, foot_y=0.08, center_x=0.50),
        "subjectWidth": 0.56, "subjectHeight": 0.60, "centerX": 0.50, "centerY": 0.42,
        "headroom": 0.22, "faceZone": (0.30, 0.68, 0.40, 0.24),
        "zoom": 1.8, "tags": ["portrait", "closeUp"], "light": (0.30, 0.90, False),
        "vi": "Cận khuôn mặt, để khoảng trống phía trên đầu.", "en": "Frame the face with headroom above.",
    },
    {
        "id": "couple-front",
        "category": "couple", "framing": "full", "orientation": "front",
        "subjectCount": 2, "cameraHints": ["eyeLevel"],
        "landmarks": couple(),
        "subjectWidth": 0.62, "subjectHeight": 0.82, "centerX": 0.50, "centerY": 0.48,
        "headroom": 0.12, "faceZone": (0.32, 0.78, 0.36, 0.16),
        "zoom": 1.0, "tags": ["group", "couple"], "light": (0.25, 0.90, False),
        "vi": "Cả hai đứng sát nhau, cùng hướng về máy.", "en": "Stand close together, both facing the camera.",
    },
    {
        "id": "couple-seated",
        "category": "couple", "framing": "medium", "orientation": "front",
        "subjectCount": 2, "cameraHints": ["eyeLevel"],
        "landmarks": couple(seated=True),
        "subjectWidth": 0.60, "subjectHeight": 0.60, "centerX": 0.50, "centerY": 0.56,
        "headroom": 0.14, "faceZone": (0.34, 0.76, 0.32, 0.16),
        "zoom": 1.1, "tags": ["group", "couple", "seated"], "light": (0.25, 0.90, False),
        "vi": "Ngồi gần nhau, vai thả lỏng.", "en": "Sit close together with relaxed shoulders.",
    },
    {
        "id": "group-three",
        "category": "smallGroup", "framing": "full", "orientation": "front",
        "subjectCount": 3, "cameraHints": ["eyeLevel"],
        "landmarks": couple(offset=0.20) | {
            **{f"subject3_{k}": v for k, v in person(center_x=0.50, lean=0.02).items()}
        },
        "subjectWidth": 0.78, "subjectHeight": 0.80, "centerX": 0.50, "centerY": 0.48,
        "headroom": 0.12, "faceZone": (0.26, 0.78, 0.48, 0.16),
        "zoom": 1.0, "tags": ["group"], "light": (0.25, 0.90, False),
        "vi": "Ba người đứng thành hàng, cách đều nhau.", "en": "Three people stand in a row, evenly spaced.",
    },
    {
        "id": "group-four",
        "category": "smallGroup", "framing": "full", "orientation": "front",
        "subjectCount": 4, "cameraHints": ["eyeLevel"],
        "landmarks": couple(offset=0.26) | {
            **{f"subject3_{k}": v for k, v in person(center_x=0.28, lean=0.01).items()},
            **{f"subject4_{k}": v for k, v in person(center_x=0.72, lean=-0.01).items()},
        },
        "subjectWidth": 0.92, "subjectHeight": 0.80, "centerX": 0.50, "centerY": 0.48,
        "headroom": 0.12, "faceZone": (0.20, 0.78, 0.60, 0.16),
        "zoom": 1.0, "tags": ["group"], "light": (0.25, 0.90, False),
        "vi": "Nhóm bốn người, tránh ai bị khuất.", "en": "Group of four with nobody blocked.",
    },
    {
        "id": "product-table",
        "category": "product", "framing": "medium", "orientation": "top",
        "subjectCount": 1, "cameraHints": ["overhead"],
        "landmarks": {},
        "subjectWidth": 0.66, "subjectHeight": 0.52, "centerX": 0.50, "centerY": 0.52,
        "headroom": 0.10, "faceZone": (0.20, 0.30, 0.60, 0.40),
        "zoom": 1.4, "tags": ["product"], "light": (0.30, 0.90, True),
        "vi": "Đặt sản phẩm giữa khung, chụp từ trên xuống.", "en": "Center the product and shoot from above.",
    },
    {
        "id": "food-overhead",
        "category": "food", "framing": "medium", "orientation": "top",
        "subjectCount": 1, "cameraHints": ["overhead"],
        "landmarks": {},
        "subjectWidth": 0.70, "subjectHeight": 0.55, "centerX": 0.50, "centerY": 0.52,
        "headroom": 0.10, "faceZone": (0.18, 0.28, 0.64, 0.44),
        "zoom": 1.3, "tags": ["food"], "light": (0.30, 0.95, True),
        "vi": "Chụp món ăn từ trên, đĩa nằm giữa khung.", "en": "Shoot the dish from above with the plate centered.",
    },
    {
        "id": "scenery-horizon",
        "category": "scenery", "framing": "wide", "orientation": "front",
        "subjectCount": 1, "cameraHints": ["level"],
        "landmarks": {},
        "subjectWidth": 0.94, "subjectHeight": 0.55, "centerX": 0.50, "centerY": 0.55,
        "headroom": 0.18, "faceZone": (0.05, 0.42, 0.90, 0.30),
        "zoom": 1.0, "tags": ["scenery"], "light": (0.35, 0.95, False),
        "vi": "Giữ đường chân trời thẳng và cân bằng.", "en": "Keep the horizon straight and balanced.",
    },
    {
        "id": "product-close",
        "category": "product", "framing": "close", "orientation": "threeQuarter",
        "subjectCount": 1, "cameraHints": ["macro"],
        "landmarks": {},
        "subjectWidth": 0.80, "subjectHeight": 0.64, "centerX": 0.50, "centerY": 0.50,
        "headroom": 0.08, "faceZone": (0.12, 0.22, 0.76, 0.50),
        "zoom": 2.0, "tags": ["product", "macro"], "light": (0.35, 0.95, True),
        "vi": "Cận chi tiết sản phẩm, nền gọn.", "en": "Close-up on the product with a clean background.",
    },
]


def mirror_landmarks(landmarks: dict) -> dict:
    def swap(name: str) -> str:
        if name.startswith("left_"):
            return "right_" + name[5:]
        if name.startswith("right_"):
            return "left_" + name[6:]
        return name

    return {
        swap(name): {"x": round(1 - point["x"], 4), "y": point["y"]}
        for name, point in landmarks.items()
    }


def scaled_seed(seed: dict, scale: float, center_y_delta: float, lean: float) -> dict:
    landmarks = {}
    for name, point in seed["landmarks"].items():
        landmarks[name] = p(
            (point["x"] - 0.5) * scale + 0.5 + lean,
            (point["y"] - seed["centerY"]) * scale + seed["centerY"] + center_y_delta,
        )
    return {
        **seed,
        "landmarks": landmarks,
        "subjectWidth": round(seed["subjectWidth"] * scale, 4),
        "subjectHeight": round(seed["subjectHeight"] * scale, 4),
        "centerY": round(seed["centerY"] + center_y_delta, 4),
        "centerX": round(min(max(seed["centerX"] + lean, 0.05), 0.95), 4),
        "headroom": round(max(seed["headroom"] - abs(center_y_delta) * 0.5, 0.06), 4),
        "faceZone": (
            round(seed["faceZone"][0] + lean, 4),
            round(seed["faceZone"][1] + center_y_delta, 4),
            round(seed["faceZone"][2], 4),
            round(seed["faceZone"][3], 4),
        ),
    }


def variants_for(seed: dict) -> list[dict]:
    """Deterministic variant grid for one seed."""
    variants: list[dict] = []
    counter = 0
    for mirror in (False, True):
        for scale in (0.90, 1.00, 1.10):
            for height in (-0.04, 0.0, 0.04):
                for lean in (0.0, 0.05):
                    base = scaled_seed(seed, scale, height, lean)
                    if mirror:
                        base = {
                            **base,
                            "landmarks": mirror_landmarks(base["landmarks"]),
                            "centerX": round(1 - base["centerX"], 4),
                            "faceZone": (
                                round(1 - base["faceZone"][0] - base["faceZone"][2], 4),
                                base["faceZone"][1],
                                base["faceZone"][2],
                                base["faceZone"][3],
                            ),
                        }
                    counter += 1
                    variants.append({
                        **base,
                        "id": f"{seed['id']}-v{counter}",
                        "orientation": "mirror" if mirror else seed["orientation"],
                    })
    return variants


def angle(a: dict, vertex: dict, b: dict) -> float:
    v1 = (a["x"] - vertex["x"], a["y"] - vertex["y"])
    v2 = (b["x"] - vertex["x"], b["y"] - vertex["y"])
    dot = v1[0] * v2[0] + v1[1] * v2[1]
    length = math.sqrt((v1[0] ** 2 + v1[1] ** 2) * (v2[0] ** 2 + v2[1] ** 2))
    if length == 0:
        return 0
    return math.degrees(math.acos(max(-1, min(1, dot / length))))


def distance(a: dict, b: dict) -> float:
    names = set(a["landmarks"]).intersection(b["landmarks"])
    if not names:
        return 1.0
    landmark_distance = sum(
        math.hypot(a["landmarks"][n]["x"] - b["landmarks"][n]["x"],
                   a["landmarks"][n]["y"] - b["landmarks"][n]["y"])
        for n in names
    ) / len(names)
    a_frame = a["targetFraming"]
    b_frame = b["targetFraming"]
    framing_distance = (
        abs(a_frame["centerX"] - b_frame["centerX"])
        + abs(a_frame["centerY"] - b_frame["centerY"])
        + abs(a_frame["subjectWidth"] - b_frame["subjectWidth"])
        + abs(a_frame["subjectHeight"] - b_frame["subjectHeight"])
    )
    return landmark_distance * 0.6 + framing_distance * 0.4


def canonical_values(template: dict) -> str:
    landmarks = sorted(
        (name, template["landmarks"][name]) for name in template["landmarks"]
    )
    landmark_part = ";".join(
        f"{name}:{point['x']:.3f},{point['y']:.3f}" for name, point in landmarks
    )
    framing = template["targetFraming"]
    return "|".join([
        template["category"],
        str(template["subjectCount"]),
        f"{framing['centerX']:.3f},{framing['centerY']:.3f},"
        f"{framing['subjectWidth']:.3f},{framing['subjectHeight']:.3f}",
        landmark_part,
    ])


def canonical_key(template: dict) -> str:
    own = canonical_values(template)
    mirrored = dict(template)
    mirrored["landmarks"] = mirror_landmarks(template["landmarks"])
    mirrored_framing = dict(template["targetFraming"])
    mirrored_framing["centerX"] = 1 - template["targetFraming"]["centerX"]
    mirrored["targetFraming"] = mirrored_framing
    face = template["faceZone"]
    mirrored["faceZone"] = {
        "x": 1 - face["x"] - face["width"],
        "y": face["y"],
        "width": face["width"],
        "height": face["height"],
    }
    return min(own, canonical_values(mirrored))


def validate(template: dict) -> bool:
    if (
        template["schemaVersion"] != SCHEMA_VERSION
        or not template["id"]
        or template["category"] not in CATEGORIES
        or not (1 <= template["subjectCount"] <= 6)
        or template["source"] != SOURCE
        or template["recommendedZoom"] < 1
        or template["headroom"] < 0.06
        or not (0 <= template["targetFraming"]["subjectWidth"] <= 1)
        or not (0 <= template["targetFraming"]["subjectHeight"] <= 1)
    ):
        return False
    face_zone = template["faceZone"]
    fx, fy, fw, fh = face_zone["x"], face_zone["y"], face_zone["width"], face_zone["height"]
    if not (0 <= fx and 0 <= fy and fx + fw <= 1 and fy + fh <= 1):
        return False
    margin = CROP_SAFETY_MARGIN
    if not (0 <= fx - margin and 0 <= fy - margin and fx + fw + margin <= 1 and fy + fh + margin <= 1):
        return False
    for point in template["landmarks"].values():
        if not (0 <= point["x"] <= 1 and 0 <= point["y"] <= 1):
            return False
    if template["category"] not in PERSON_CATEGORIES:
        return True
    points = template["landmarks"]
    for side in ("left", "right"):
        knee = angle(points[f"{side}_hip"], points[f"{side}_knee"], points[f"{side}_ankle"])
        if not (25 <= knee <= 175):
            return False
        elbow = angle(
            points[f"{side}_shoulder"], points[f"{side}_elbow"], points[f"{side}_hand"]
        )
        if not (10 <= elbow <= 170):
            return False
    torso = (
        math.hypot(*[points["left_shoulder"][k] - points["right_shoulder"][k] for k in ("x", "y")])
        + math.hypot(*[points["left_hip"][k] - points["right_hip"][k] for k in ("x", "y")])
    )
    leg = (
        math.hypot(*[points["left_hip"][k] - points["left_ankle"][k] for k in ("x", "y")])
        + math.hypot(*[points["right_hip"][k] - points["right_ankle"][k] for k in ("x", "y")])
    )
    if not (0.25 <= torso / max(leg, 1e-9) <= 2.0):
        return False
    if max(point["y"] for point in points.values()) > 0.93:
        return False
    return True


def build_bundle() -> list[dict]:
    templates: list[dict] = []
    for seed in SEEDS:
        for variant in variants_for(seed):
            template = {
                "schemaVersion": SCHEMA_VERSION,
                "id": variant["id"],
                "category": variant["category"],
                "framing": variant["framing"],
                "orientation": variant["orientation"],
                "subjectCount": variant["subjectCount"],
                "cameraHints": variant["cameraHints"],
                "landmarks": variant["landmarks"],
                "targetFraming": {
                    "subjectWidth": variant["subjectWidth"],
                    "subjectHeight": variant["subjectHeight"],
                    "centerX": variant["centerX"],
                    "centerY": variant["centerY"],
                },
                "headroom": variant["headroom"],
                "faceZone": {
                    "x": variant["faceZone"][0],
                    "y": variant["faceZone"][1],
                    "width": variant["faceZone"][2],
                    "height": variant["faceZone"][3],
                },
                "recommendedZoom": variant["zoom"],
                "contextTags": variant["tags"],
                "lightingConstraints": {
                    "minLuma": variant["light"][0],
                    "maxLuma": variant["light"][1],
                    "avoidBacklit": variant["light"][2],
                },
                "instructionVI": variant["vi"],
                "instructionEN": variant["en"],
                "source": SOURCE,
            }
            if not validate(template):
                continue
            templates.append(template)

    # Deduplicate: mirror-equivalent canonical keys, then distance threshold.
    by_key: dict[str, dict] = {}
    for template in sorted(templates, key=lambda t: t["id"]):
        key = canonical_key(template)
        if key in by_key:
            continue
        if any(distance(template, accepted) < DISTANCE_THRESHOLD for accepted in by_key.values()):
            continue
        by_key[key] = template
    return list(by_key.values())


def main() -> int:
    root = pathlib.Path(__file__).resolve().parent.parent
    output = root / "Focelle" / "Coach" / "PoseTemplates.json"
    templates = build_bundle()
    if not (MIN_COUNT <= len(templates) <= MAX_COUNT):
        print(f"generated {len(templates)} templates; expected {MIN_COUNT}-{MAX_COUNT}", file=sys.stderr)
        return 1
    bundle = {
        "schemaVersion": SCHEMA_VERSION,
        "seedCount": len(SEEDS),
        "generatedCount": len(templates),
        "generation": "focelle-coach-a-1",
        "templates": templates,
    }
    output.write_text(
        json.dumps(bundle, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(f"wrote {len(templates)} templates ({len(SEEDS)} seeds) to {output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
