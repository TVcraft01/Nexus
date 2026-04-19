"""Countdown, age calculator, days between dates. No AI, no network."""
import re
import time
from datetime import datetime, date

NAME = "Dates & Countdown"
DESCRIPTION = "Days until a date, days between dates, age calculator, day of week."
CAPABILITIES = []
PATTERNS = [
    r"(how many days?|combien de jours?).{0,20}(until|until|before|avant|till)",
    r"(days? until|days? till|jours? avant|jours? jusqu)",
    r"(countdown|compte à rebours).{0,30}",
    r"(how old|quel âge|my age).{0,20}(am i|born|naissance|birthday)?",
    r"(born|né[e]?).{0,20}(\d{4}|\d{1,2}[\/\-]\d{1,2}[\/\-]\d{4})",
    r"(age|âge).{0,20}(born|naissance|birthday|anniversaire)?",
    r"(days? between|entre.{0,10}dates?|diff.{0,10}dates?)",
    r"(what day|quel jour).{0,20}(is|was|sera|était).{0,30}\d",
    r"(day of the week|jour de la semaine).{0,30}\d",
    r"(leap year|année bissextile).{0,20}\d{4}",
]


def handle(text, lower, language, memory=None):
    fr = language.startswith("fr")
    today = date.today()

    # Age calculator
    age_match = re.search(r"(\d{1,2})[\/\-\.](\d{1,2})[\/\-\.](\d{4})", lower)
    if not age_match:
        age_match = re.search(r"(\d{4})", lower)
        if age_match and (re.search(r"(born|né|âge|age|old|birthday|anniversaire)", lower)):
            year = int(age_match.group(1))
            age = today.year - year
            if age >= 0:
                return {"response": f"{age} years old." if not fr else f"{age} ans.", "intent": "countdown"}

    if age_match and len(age_match.groups()) == 3:
        try:
            d, m, y = int(age_match.group(1)), int(age_match.group(2)), int(age_match.group(3))
            born = date(y, m, d)
            age = (today - born).days // 365
            days_old = (today - born).days
            return {"response": (f"{age} years old ({days_old:,} days)." if not fr
                                  else f"{age} ans ({days_old:,} jours)."),
                    "intent": "countdown"}
        except ValueError:
            pass

    # Leap year
    leap_match = re.search(r"(leap year|année bissextile).{0,10}(\d{4})", lower)
    if leap_match:
        year = int(leap_match.group(2))
        is_leap = (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0)
        return {"response": (f"{year} is a leap year." if is_leap else f"{year} is not a leap year.") if not fr
                else (f"{year} est une année bissextile." if is_leap else f"{year} n'est pas une année bissextile."),
                "intent": "countdown"}

    # What day of the week was/is a date
    dow_match = re.search(r"(\d{1,2})[\/\-\.](\d{1,2})[\/\-\.](\d{4})", lower)
    if dow_match and re.search(r"(what day|quel jour|day of)", lower):
        try:
            d, m, y = int(dow_match.group(1)), int(dow_match.group(2)), int(dow_match.group(3))
            dt = date(y, m, d)
            days_en = ["Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday"]
            days_fr = ["lundi","mardi","mercredi","jeudi","vendredi","samedi","dimanche"]
            day_name = days_fr[dt.weekday()] if fr else days_en[dt.weekday()]
            return {"response": f"{day_name}.", "intent": "countdown"}
        except ValueError:
            pass

    # Days until a date — supports "December 25", "25/12/2025", "Christmas"
    named = _named_date(lower, today)
    if named and re.search(r"(until|till|avant|jusqu|countdown|days?)", lower):
        delta = (named[0] - today).days
        label = named[1]
        if delta < 0:
            delta += 365  # next year
            return {"response": (f"{delta} days until {label} (next year)." if not fr
                                  else f"{delta} jours avant {label} (l'an prochain)."),
                    "intent": "countdown"}
        elif delta == 0:
            return {"response": (f"Today is {label}!" if not fr else f"C'est {label} aujourd'hui !"),
                    "intent": "countdown"}
        return {"response": (f"{delta} days until {label}." if not fr
                              else f"{delta} jours avant {label}."),
                "intent": "countdown"}

    # Days between two dates
    dates = re.findall(r"(\d{1,2})[\/\-\.](\d{1,2})[\/\-\.](\d{4})", lower)
    if len(dates) >= 2:
        try:
            d1 = date(int(dates[0][2]), int(dates[0][1]), int(dates[0][0]))
            d2 = date(int(dates[1][2]), int(dates[1][1]), int(dates[1][0]))
            diff = abs((d2 - d1).days)
            return {"response": f"{diff} days." if not fr else f"{diff} jours.", "intent": "countdown"}
        except ValueError:
            pass

    # Fallback: just try to extract a month name and give days until it
    month_match = re.search(
        r"(january|february|march|april|may|june|july|august|september|october|november|december|"
        r"janvier|février|mars|avril|mai|juin|juillet|août|septembre|octobre|novembre|décembre)",
        lower
    )
    if month_match and re.search(r"(until|till|avant|jusqu|days?|jours?)", lower):
        month_names = {
            "january":1,"february":2,"march":3,"april":4,"may":5,"june":6,
            "july":7,"august":8,"september":9,"october":10,"november":11,"december":12,
            "janvier":1,"février":2,"mars":3,"avril":4,"mai":5,"juin":6,
            "juillet":7,"août":8,"septembre":9,"octobre":10,"novembre":11,"décembre":12,
        }
        m = month_names.get(month_match.group(1), 0)
        if m:
            day_match = re.search(r"(\d{1,2})", lower)
            day = int(day_match.group(1)) if day_match else 1
            try:
                target = date(today.year, m, day)
                if target < today:
                    target = date(today.year + 1, m, day)
                delta = (target - today).days
                return {"response": f"{delta} days." if not fr else f"{delta} jours.", "intent": "countdown"}
            except ValueError:
                pass

    return None


def _named_date(lower, today):
    """Return (date, label) for common named dates."""
    year = today.year
    named = {
        "christmas": (date(year, 12, 25), "Christmas"),
        "new year":  (date(year + 1, 1, 1) if today >= date(year, 1, 1) else date(year, 1, 1), "New Year"),
        "halloween": (date(year, 10, 31), "Halloween"),
        "valentine": (date(year, 2, 14), "Valentine's Day"),
        "noël":      (date(year, 12, 25), "Noël"),
        "nouvel an": (date(year + 1, 1, 1), "Nouvel An"),
    }
    for keyword, value in named.items():
        if keyword in lower:
            return value
    return None
