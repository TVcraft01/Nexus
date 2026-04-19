"""Random tools — dice, coin, numbers, shuffle, pick. No AI, no network."""
import re
import random
import string

NAME = "Random & Chance"
DESCRIPTION = "Roll dice, flip coins, pick random numbers, shuffle lists, generate passwords."
CAPABILITIES = []
PATTERNS = [
    r"(roll|lance[rz]?).{0,20}(dice|dé|d\d+)",
    r"d\d+",
    r"(flip|toss|lance[rz]?).{0,10}(coin|pièce|pile ou face)",
    r"(random|aléatoire).{0,30}(number|chiffre|nombre|pick|choice|choose)",
    r"(pick|choose|choisir).{0,20}(random|between|parmi|entre|from)",
    r"(between|entre) \d+.{0,10}\d+",
    r"(shuffle|mélange[rz]?).{0,40}",
    r"(generate|créer?).{0,20}(password|mot de passe|passphrase)",
    r"(password|mot de passe).{0,20}(generate|créer?|random|aléatoire)?",
    r"(uuid|unique id|identifiant)",
    r"(8ball|magic ball|boule magique|fortune)",
    r"(yes or no|oui ou non).{0,10}(random|aléatoire)?",
]

EIGHT_BALL = [
    "Yes.", "Definitely.", "Without a doubt.", "Most likely.", "Outlook good.",
    "Signs point to yes.", "Ask again later.", "Cannot predict now.",
    "Don't count on it.", "My reply is no.", "Very doubtful.", "Absolutely not.",
]

YES_NO = ["Yes.", "No.", "Maybe.", "Definitely yes.", "Definitely no.", "Ask me later."]


def handle(text, lower, language, memory=None):
    fr = language.startswith("fr")

    # 8-ball / fortune
    if any(w in lower for w in ["8ball", "magic ball", "boule magique", "fortune"]):
        return {"response": random.choice(EIGHT_BALL), "intent": "random"}

    # Yes or no
    if re.search(r"yes or no|oui ou non", lower):
        return {"response": random.choice(YES_NO), "intent": "random"}

    # Coin flip
    if re.search(r"(flip|toss|lance).{0,10}(coin|pièce|pile)", lower):
        result = random.choice(["Heads" if not fr else "Face", "Tails" if not fr else "Pile"])
        return {"response": result + ".", "intent": "random"}

    # Dice roll — supports d6, d20, 2d6, etc.
    dice_match = re.search(r"(\d+)?d(\d+)", lower)
    if dice_match or re.search(r"(roll|lance).{0,10}(dice|dé)", lower):
        if dice_match:
            count = int(dice_match.group(1) or 1)
            sides = int(dice_match.group(2))
        else:
            count, sides = 1, 6
        count = min(count, 20)
        sides = min(sides, 1000)
        rolls = [random.randint(1, sides) for _ in range(count)]
        total = sum(rolls)
        if count == 1:
            return {"response": f"{rolls[0]}", "intent": "random"}
        rolls_str = " + ".join(str(r) for r in rolls)
        return {"response": f"{rolls_str} = {total}", "intent": "random"}

    # Password generator
    if re.search(r"(password|mot de passe)", lower):
        length_match = re.search(r"(\d+)", lower)
        length = int(length_match.group(1)) if length_match else 16
        length = max(8, min(length, 64))
        chars = string.ascii_letters + string.digits + "!@#$%^&*"
        pwd = "".join(random.choices(chars, k=length))
        return {"response": pwd, "intent": "random"}

    # UUID
    if "uuid" in lower or "unique id" in lower or "identifiant" in lower:
        import uuid
        return {"response": str(uuid.uuid4()), "intent": "random"}

    # Shuffle a list
    shuffle_match = re.search(r"(shuffle|mélange[rz]?)[: ]+(.+)", lower)
    if shuffle_match:
        items = [i.strip() for i in re.split(r"[,;]", shuffle_match.group(2)) if i.strip()]
        if items:
            random.shuffle(items)
            return {"response": ", ".join(items), "intent": "random"}

    # Pick from list
    pick_match = re.search(r"(pick|choose|choisir).{0,10}(?:from|parmi|between|entre)[: ]+(.+)", lower)
    if pick_match:
        items = [i.strip() for i in re.split(r"[,;]|\ or\ |\ ou\ ", pick_match.group(2)) if i.strip()]
        if items:
            return {"response": random.choice(items), "intent": "random"}

    # Random number between X and Y
    range_match = re.search(r"(?:between|entre)\s+(\d+)\s+(?:and|et|to|-)\s+(\d+)", lower)
    if range_match:
        lo, hi = int(range_match.group(1)), int(range_match.group(2))
        if lo > hi:
            lo, hi = hi, lo
        return {"response": str(random.randint(lo, hi)), "intent": "random"}

    # Generic "random number"
    if re.search(r"random.{0,10}(number|nombre|chiffre)", lower):
        return {"response": str(random.randint(1, 100)), "intent": "random"}

    return None
