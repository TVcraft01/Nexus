"""Text tools — word count, case, reverse, hash, morse, etc. No AI, no network."""
import re
import hashlib

NAME = "Text Tools"
DESCRIPTION = "Word count, uppercase, reverse, hash, morse code, character count."
CAPABILITIES = []
PATTERNS = [
    r"(word count|count words?|combien de mots?)",
    r"(uppercase|majuscule[s]?|upper case|all caps)",
    r"(lowercase|minuscule[s]?|lower case)",
    r"(reverse|inverser?|backwards?).{0,20}(text|word|string|this|phrase|mot)",
    r"(count|compter?).{0,20}(char|letter|lettre|caractère)",
    r"(md5|sha1|sha256|hash).{0,20}(of|de|this)?",
    r"(morse).{0,30}",
    r"(encode|décoder?|encode[rz]?).{0,20}(morse)",
    r"(base64|b64).{0,20}(encode|decode)",
    r"(palindrome).{0,30}",
    r"(how many (words?|letters?|chars?|characters?))",
]

MORSE = {
    'a':'.-','b':'-...','c':'-.-.','d':'-..','e':'.','f':'..-.','g':'--.','h':'....','i':'..','j':'.---',
    'k':'-.-','l':'.-..','m':'--','n':'-.','o':'---','p':'.--.','q':'--.-','r':'.-.','s':'...','t':'-',
    'u':'..-','v':'...-','w':'.--','x':'-..-','y':'-.--','z':'--..',
    '0':'-----','1':'.----','2':'..---','3':'...--','4':'....-','5':'.....',
    '6':'-....','7':'--...','8':'---..','9':'----.',
    ' ': ' / ',
}


def handle(text, lower, language, memory=None):
    fr = language.startswith("fr")

    # Extract quoted content first
    quoted = re.search(r'["\'](.+?)["\']', text)
    payload = quoted.group(1) if quoted else None

    # Word count
    if re.search(r"(word count|count words?|combien de mots?|how many words?)", lower):
        target = payload or _strip_command(text)
        words = len(target.split())
        return {"response": f"{words} word{'s' if words != 1 else ''}" if not fr else f"{words} mot{'s' if words != 1 else ''}",
                "intent": "text_tools"}

    # Character count
    if re.search(r"(how many (char|letter|lettre|caractère)|count (char|letter))", lower):
        target = payload or _strip_command(text)
        chars = len(target.replace(" ", ""))
        total = len(target)
        return {"response": f"{chars} characters (no spaces), {total} total" if not fr
                else f"{chars} caractères (sans espaces), {total} au total",
                "intent": "text_tools"}

    # Uppercase
    if re.search(r"(uppercase|majuscule|upper case|all caps)", lower):
        target = payload or _strip_command(text)
        return {"response": target.upper(), "intent": "text_tools"}

    # Lowercase
    if re.search(r"(lowercase|minuscule|lower case)", lower):
        target = payload or _strip_command(text)
        return {"response": target.lower(), "intent": "text_tools"}

    # Reverse
    if re.search(r"(reverse|inverser?|backwards?)", lower):
        target = payload or _strip_command(text)
        return {"response": target[::-1], "intent": "text_tools"}

    # Palindrome check
    if "palindrome" in lower:
        target = payload or _strip_command(text)
        clean = re.sub(r"[^a-z0-9]", "", target.lower())
        is_p = clean == clean[::-1]
        return {"response": (f"Yes, '{target}' is a palindrome." if is_p
                              else f"No, '{target}' is not a palindrome.") if not fr
                else (f"Oui, '{target}' est un palindrome." if is_p
                      else f"Non, '{target}' n'est pas un palindrome."),
                "intent": "text_tools"}

    # Hash
    hash_match = re.search(r"(md5|sha1|sha256|sha512)", lower)
    if hash_match:
        algo = hash_match.group(1)
        target = payload or _strip_command(text, remove=algo)
        h = hashlib.new(algo, target.encode()).hexdigest()
        return {"response": f"{algo.upper()}: {h}", "intent": "text_tools"}

    # Morse encode
    if re.search(r"(morse|encode.{0,10}morse|to morse)", lower):
        target = payload or _strip_command(text, remove="morse")
        encoded = " ".join(MORSE.get(c.lower(), "?") for c in target)
        return {"response": encoded, "intent": "text_tools"}

    # Base64
    if re.search(r"(base64|b64)", lower):
        import base64
        if "decode" in lower:
            try:
                target = payload or _strip_command(text, remove="base64 decode")
                decoded = base64.b64decode(target.strip()).decode("utf-8", errors="replace")
                return {"response": decoded, "intent": "text_tools"}
            except Exception:
                return {"response": "Invalid base64." if not fr else "Base64 invalide.", "intent": "text_tools"}
        else:
            target = payload or _strip_command(text, remove="base64 encode")
            encoded = base64.b64encode(target.encode()).decode()
            return {"response": encoded, "intent": "text_tools"}

    return None


def _strip_command(text, remove=None):
    """Remove command keywords from start of text to get the payload."""
    clean = re.sub(
        r"^(word count|count words?|uppercase|lowercase|reverse|backwards?|"
        r"encode|decode|hash|morse|base64|b64|palindrome|of|de|this|:)\s*",
        "", text.strip(), flags=re.I
    ).strip(' "\'')
    if remove:
        clean = re.sub(re.escape(remove), "", clean, flags=re.I).strip()
    return clean if clean else text
