"""Unit Converter — no AI, no network."""
import re

NAME = "Unit Converter"
DESCRIPTION = "Convert between length, weight, temperature, speed, volume, area."
CAPABILITIES = []
PATTERNS = [
    r"\d+\s*(km|miles?|meter|metre|cm|mm|inch|inches|foot|feet|yard|furlong)",
    r"\d+\s*(kg|lbs?|pounds?|gram|oz|ounce|tonne|ton)",
    r"\d+\s*(celsius|fahrenheit|kelvin|°c|°f|°k|degrees?)",
    r"\d+\s*(mph|kph|km/h|m/s|knots?)",
    r"\d+\s*(liter|litre|gallon|ml|milliliter|fluid ounce|fl oz|pint|quart|cup)",
    r"convert.{0,40}\d+",
    r"\d+.{0,10}(to|en|in|into|=|->).{0,20}(km|mile|kg|lb|celsius|fahrenheit|meter|liter|mph|m3|m³|litre|gallon)",
]

# ── Conversion tables ──────────────────────────────────────────────────────────
LENGTH_TO_M = {
    "km": 1000, "kilometer": 1000, "kilometres": 1000,
    "mile": 1609.344, "miles": 1609.344,
    "m": 1, "meter": 1, "metre": 1,
    "cm": 0.01, "centimeter": 0.01,
    "mm": 0.001, "millimeter": 0.001,
    "inch": 0.0254, "inches": 0.0254, "in": 0.0254,
    "foot": 0.3048, "feet": 0.3048, "ft": 0.3048,
    "yard": 0.9144, "yards": 0.9144, "yd": 0.9144,
}

WEIGHT_TO_KG = {
    "kg": 1, "kilogram": 1, "kilograms": 1,
    "g": 0.001, "gram": 0.001, "grams": 0.001,
    "lb": 0.453592, "lbs": 0.453592, "pound": 0.453592, "pounds": 0.453592,
    "oz": 0.0283495, "ounce": 0.0283495, "ounces": 0.0283495,
    "tonne": 1000, "ton": 907.185,
}

SPEED_TO_MPS = {
    "mph": 0.44704, "kph": 1/3.6, "km/h": 1/3.6,
    "m/s": 1, "knot": 0.514444, "knots": 0.514444,
}

VOLUME_TO_L = {
    "l": 1, "L": 1, "liter": 1, "litre": 1, "liters": 1, "litres": 1,
    "ml": 0.001, "milliliter": 0.001, "millilitre": 0.001,
    "gallon": 3.78541, "gallons": 3.78541,
    "pint": 0.473176, "pints": 0.473176,
    "cup": 0.236588, "cups": 0.236588,
    "fl oz": 0.0295735, "fluid ounce": 0.0295735,
    "quart": 0.946353, "quarts": 0.946353,
    "m3": 1000, "m³": 1000, "cubic meter": 1000, "cubic metre": 1000,
    "cm3": 0.001, "cm³": 0.001, "cubic centimeter": 0.001,
}


def handle(text, lower, language, memory=None):
    fr = language.startswith("fr")

    # Temperature first
    temp = _try_temperature(lower)
    if temp:
        return {"response": temp, "intent": "unit_converter"}

    # Try "X unit1 to/in/en unit2" — allow unicode like m³
    match = re.search(
        r"([\d\.]+)\s*([a-zA-Z\u00b2\u00b3/°\d ]{1,15}?)\s*(?:to|en|in|into|=|->)\s*([a-zA-Z\u00b2\u00b3/°\d ]{1,15})",
        lower
    )
    if match:
        amount = float(match.group(1))
        from_unit = match.group(2).strip().rstrip("s ")
        to_unit   = match.group(3).strip().rstrip("s ")
        # Try exact, then stripped
        for fu, tu in [(from_unit, to_unit),
                       (match.group(2).strip(), match.group(3).strip())]:
            result = _convert(amount, fu, tu)
            if result:
                return {"response": result, "intent": "unit_converter"}

    # Single value+unit — auto-pair
    single = re.search(r"([\d\.]+)\s*([a-zA-Z²³/°]{1,10})", lower)
    if single:
        amount = float(single.group(1))
        unit = single.group(2).strip()
        result = _auto_convert(amount, unit)
        if result:
            return {"response": result, "intent": "unit_converter"}

    msg = ("Donne-moi quelque chose comme '5 km en miles' ou '100°F en Celsius'." if fr
           else "Give me something like '5 km to miles' or '100°F to Celsius'.")
    return {"response": msg, "intent": "unit_converter"}


def _try_temperature(lower):
    m = re.search(r"([\-\d\.]+)\s*(?:°)?(celsius|fahrenheit|kelvin|c|f|k)\b", lower)
    if not m:
        return None
    val = float(m.group(1))
    unit = m.group(2).lower()[0]

    results = []
    if unit == "c":
        results.append(f"{val:.1f}°C = {val * 9/5 + 32:.1f}°F")
        results.append(f"{val:.1f}°C = {val + 273.15:.2f} K")
    elif unit == "f":
        c = (val - 32) * 5/9
        results.append(f"{val:.1f}°F = {c:.1f}°C")
        results.append(f"{val:.1f}°F = {c + 273.15:.2f} K")
    elif unit == "k":
        c = val - 273.15
        results.append(f"{val:.2f} K = {c:.1f}°C")
        results.append(f"{val:.2f} K = {c * 9/5 + 32:.1f}°F")

    return "\n".join(results) if results else None


def _convert(amount, from_unit, to_unit):
    # Normalise units
    fu = from_unit.strip().lower().rstrip("s")
    tu = to_unit.strip().lower().rstrip("s")
    # Also try original
    for table, label in [
        (LENGTH_TO_M,   "m"),
        (WEIGHT_TO_KG,  "kg"),
        (SPEED_TO_MPS,  "m/s"),
        (VOLUME_TO_L,   "L"),
    ]:
        f = from_unit if from_unit in table else fu
        t = to_unit if to_unit in table else tu
        if f in table and t in table:
            base = amount * table[f]
            result = base / table[t]
            return f"{amount:g} {from_unit} = {_fmt(result)} {to_unit}"
    return None


def _auto_convert(amount, unit):
    pairs = {
        "km": ("miles", 0.621371),
        "miles": ("km", 1.60934),
        "kg": ("lbs", 2.20462),
        "lbs": ("kg", 0.453592),
        "m": ("ft", 3.28084),
        "ft": ("m", 0.3048),
        "celsius": ("fahrenheit", None),
        "fahrenheit": ("celsius", None),
        "c": ("fahrenheit", None),
        "f": ("celsius", None),
    }
    if unit in pairs:
        to_unit, factor = pairs[unit]
        if factor:
            return f"{amount:g} {unit} = {_fmt(amount * factor)} {to_unit}"
        else:
            return _try_temperature(f"{amount} {unit}")
    return None


def _fmt(val):
    if val == int(val):
        return str(int(val))
    return f"{val:.4g}"
