"""
Nexus Skill Loader
==================
Loads and runs skills from the skills/ directory.
Each skill needs a manifest.json and an entry point with a run() function.
"""
import os, json, importlib.util

SKILLS_DIR = os.path.join(os.path.dirname(__file__), "..", "skills")

class SkillLoader:
    def __init__(self):
        self.loaded = {}

    def scan(self):
        skills = []
        if not os.path.exists(SKILLS_DIR): return skills
        for name in os.listdir(SKILLS_DIR):
            manifest_path = os.path.join(SKILLS_DIR, name, "manifest.json")
            if os.path.exists(manifest_path):
                with open(manifest_path) as f:
                    skills.append(json.load(f))
        return skills

    def load(self, skill_id: str):
        skill_dir = os.path.join(SKILLS_DIR, skill_id)
        manifest_path = os.path.join(skill_dir, "manifest.json")
        if not os.path.exists(manifest_path):
            raise FileNotFoundError(f"Skill '{skill_id}' not found")
        with open(manifest_path) as f:
            manifest = json.load(f)
        entry = os.path.join(skill_dir, manifest["entry"])
        spec  = importlib.util.spec_from_file_location(skill_id, entry)
        mod   = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        self.loaded[skill_id] = mod
        return mod

    def run(self, skill_id: str, **kwargs):
        if skill_id not in self.loaded: self.load(skill_id)
        mod = self.loaded[skill_id]
        if hasattr(mod, "run"): return mod.run(**kwargs)
        raise AttributeError(f"Skill '{skill_id}' has no run() function")
