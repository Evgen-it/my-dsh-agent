#!/usr/bin/env python3
"""Слить патч от integrations.harness с cordis.patch.yml профиля DSH.

- Слияние по id: новые элементы перезаписывают старые с тем же id,
  остальные существующие элементы сохраняются (например, dsh-command-context-trim).
- Дедупликация моделей: для каждого элемента, у которого есть config.models,
  удаляются «префиксные» варианты (provider/model), если есть базовый (model).
"""
import sys
import os
from pathlib import Path
from ruamel.yaml import YAML

yaml = YAML()
yaml.preserve_quotes = True
yaml.width = 4096  # чтобы длинные строки не сворачивались


def _base(name: str) -> str:
    """'qwen/qwen3.8-max' -> 'qwen3.8-max'; 'qwen3.8-max' -> 'qwen3.8-max'."""
    return name.rsplit("/", 1)[-1] if "/" in name else name


def dedupe_models(obj):
    """Рекурсивно чистит config.models от префиксных дублей."""
    if isinstance(obj, dict):
        models = obj.get("models")
        if isinstance(models, list):
            # Вариант 1: список строк/словарей с полем id
            kept, seen = [], set()
            for entry in models:
                name = entry if isinstance(entry, str) else entry.get("id")
                if not name:
                    kept.append(entry)
                    continue
                base = _base(name)
                if base in seen:
                    continue
                # приоритет базовому имени (без префикса)
                if name != base and any(
                    (m if isinstance(m, str) else m.get("id")) == base for m in models
                ):
                    continue
                seen.add(base)
                kept.append(entry)
            obj["models"] = kept
        elif isinstance(models, dict):
            # Вариант 2: мапа id -> конфиг
            keys = list(models.keys())
            bases = {_base(k) for k in keys}
            new_models = {}
            for k in keys:
                base = _base(k)
                if k == base:
                    new_models[k] = models[k]
                elif base not in models:
                    new_models[k] = models[k]
                # иначе — префиксный дубль, пропускаем
            obj["models"] = new_models
        for v in obj.values():
            dedupe_models(v)
    elif isinstance(obj, list):
        for item in obj:
            dedupe_models(item)


def main():
    if len(sys.argv) != 3:
        print("usage: merge_patch.py <generated> <target>", file=sys.stderr)
        sys.exit(2)

    generated_path = Path(sys.argv[1])
    target_path = Path(sys.argv[2])

    with generated_path.open("r", encoding="utf-8") as f:
        generated = yaml.load(f) or []
    dedupe_models(generated)

    if target_path.exists():
        with target_path.open("r", encoding="utf-8") as f:
            existing = yaml.load(f) or []
    else:
        existing = []

    index = {
        item.get("id"): i
        for i, item in enumerate(existing)
        if isinstance(item, dict) and "id" in item
    }

    added, replaced = 0, 0
    for item in generated:
        if not isinstance(item, dict) or "id" not in item:
            existing.append(item)
            added += 1
            continue
        if item["id"] in index:
            existing[index[item["id"]]] = item
            replaced += 1
        else:
            existing.append(item)
            added += 1

    with target_path.open("w", encoding="utf-8") as f:
        yaml.dump(existing, f)

    # Файл записан от root (в контейнере моста), но DSH работает от node.
    # Разрешаем запись всем, чтобы dsh-command-context-trim мог дописать конфиг.
    os.chmod(target_path, 0o666)

    print(f"[merge_patch] добавлено {added}, заменено {replaced} → {target_path}")

if __name__ == "__main__":
    main()