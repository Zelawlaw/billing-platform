#!/usr/bin/env python3
"""
generate.py — render a Kill Bill catalog XML from a prices.yml source of truth.

Usage:
    python3 generate.py prices.yml inua/catalog-v1.xml
    python3 generate.py prices.yml --validate-only

What it guarantees:
  * Element ordering matches Kill Bill's catalog schema (verified against the
    DefaultPlanPhase / DefaultUsage JAXB field order):
      catalog: effectiveDate, catalogName, recurringBillingMode, currencies,
               units, products, rules, plans, priceLists
      phase:   duration, fixed, recurring, usages
      usage:   @name @billingMode @usageType, billingPeriod, tiers
  * EVERY priced element carries a value for EVERY declared currency, or it
    refuses to generate (this is the multi-currency safety net).
  * Names are valid Kill Bill identifiers (NCName-ish: letter-led, no spaces or
    symbols other than - and _).

It deliberately covers the common shape we use (trial? -> evergreen with
one-time fixed setup + recurring base + CONSUMABLE in-arrear usage). If you need
CAPACITY usage, DISCOUNT/FIXEDTERM phases, tiers, or add-ons, extend emit_usage
/ emit_plan — the structure is the same, just more elements.

After generating, ALWAYS validate against the running tenant before trusting it:
    POST /1.0/kb/catalog/xml/validation   (see Kill Bill catalog validation API)
"""

import sys
import re
import xml.etree.ElementTree as ET

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required:  pip install pyyaml")

NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_-]*$")
VALID_BILLING_PERIODS = {
    "DAILY", "WEEKLY", "BIWEEKLY", "THIRTY_DAYS", "MONTHLY", "BIMESTRIAL",
    "QUARTERLY", "TRIANNUAL", "BIANNUAL", "ANNUAL", "BIENNIAL", "NO_BILLING_PERIOD",
}


class CatalogError(Exception):
    pass


def check_name(name, kind):
    if not isinstance(name, str) or not NAME_RE.match(name):
        raise CatalogError(
            f"{kind} name {name!r} is not a valid Kill Bill identifier "
            f"(must start with a letter/underscore; only letters, digits, '-' and '_')."
        )
    return name


def normalize_price(value, currencies, where, is_rate):
    """Return {currency: 'value'} for all declared currencies, or raise.

    - None        -> 0 for every currency (used for setup/base defaults).
    - scalar      -> same value for every currency. For usage RATES we refuse a
                     scalar when >1 currency is declared, to force a deliberate
                     local rate per currency (a rate is a business decision, not
                     an FX conversion).
    - mapping     -> must contain every declared currency; extras are warned.
    """
    if value is None:
        return {c: "0" for c in currencies}

    if isinstance(value, dict):
        missing = [c for c in currencies if c not in value]
        if missing:
            raise CatalogError(
                f"{where}: missing price for currency/currencies {missing}. "
                f"Every declared currency needs a value."
            )
        extras = [c for c in value if c not in currencies]
        if extras:
            print(f"  warn: {where}: prices for undeclared currencies {extras} "
                  f"will be ignored until you add them to `currencies`.", file=sys.stderr)
        return {c: _fmt(value[c]) for c in currencies}

    # scalar
    if is_rate and len(currencies) > 1:
        raise CatalogError(
            f"{where}: a single scalar rate is ambiguous with multiple currencies "
            f"{currencies}. Provide an explicit per-currency map, e.g. "
            f"{{ {currencies[0]}: <num>, ... }} — set the real local rate per currency."
        )
    return {c: _fmt(value) for c in currencies}


def _fmt(v):
    if isinstance(v, bool):
        raise CatalogError(f"price value {v!r} is a boolean, expected a number")
    if isinstance(v, (int, float)):
        # avoid scientific notation / trailing noise
        return ("%f" % v).rstrip("0").rstrip(".") if isinstance(v, float) else str(v)
    s = str(v).strip()
    float(s)  # raises ValueError if not numeric
    return s


# ----------------------------- XML emission ---------------------------------
class X:
    """Tiny ordered XML writer (keeps us in full control of element order)."""
    def __init__(self):
        self.lines = []
        self.depth = 0

    def _ind(self):
        return "  " * self.depth

    def open(self, tag, **attrs):
        a = "".join(f' {k}="{_esc(v)}"' for k, v in attrs.items())
        self.lines.append(f"{self._ind()}<{tag}{a}>")
        self.depth += 1

    def close(self, tag):
        self.depth -= 1
        self.lines.append(f"{self._ind()}</{tag}>")

    def leaf(self, tag, text="", **attrs):
        a = "".join(f' {k}="{_esc(v)}"' for k, v in attrs.items())
        if text == "" and not attrs:
            self.lines.append(f"{self._ind()}<{tag}/>")
        elif text == "":
            self.lines.append(f"{self._ind()}<{tag}{a}/>")
        else:
            self.lines.append(f"{self._ind()}<{tag}{a}>{_esc(text)}</{tag}>")

    def comment(self, text):
        self.lines.append(f"{self._ind()}<!-- {text} -->")

    def render(self):
        return "\n".join(self.lines) + "\n"


def _esc(v):
    return (str(v).replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;").replace('"', "&quot;"))


def emit_prices(x, wrapper, price_map):
    """<wrapper><price><currency/><value/></price>...</wrapper>"""
    x.open(wrapper)
    for cur, val in price_map.items():
        x.open("price")
        x.leaf("currency", cur)
        x.leaf("value", val)
        x.close("price")
    x.close(wrapper)


def emit_usage(x, u, currencies):
    name = check_name(u["name"], "usage")
    unit = check_name(u["unit"], "unit")
    rate = normalize_price(u["rate"], currencies, f"usage {name} rate", is_rate=True)
    bp = u.get("billing_period")  # defaults to the plan billing period upstream
    x.open("usage", name=name, billingMode="IN_ARREAR", usageType="CONSUMABLE")
    x.leaf("billingPeriod", bp)
    x.open("tiers")
    x.open("tier")
    x.open("blocks")
    x.open("tieredBlock")
    x.leaf("unit", unit)
    x.leaf("size", "1")
    emit_prices(x, "prices", rate)
    x.leaf("max", "-1")
    x.close("tieredBlock")
    x.close("blocks")
    x.close("tier")
    x.close("tiers")
    x.close("usage")


def emit_plan(x, p, currencies, default_trial):
    name = check_name(p["name"], "plan")
    product = check_name(p["product"], "product")
    bp = p["billing_period"]
    if bp not in VALID_BILLING_PERIODS:
        raise CatalogError(f"plan {name}: billing_period {bp!r} is not valid")
    trial_days = p.get("trial_days", default_trial)
    setup = normalize_price(p.get("setup_fixed"), currencies, f"plan {name} setup_fixed", is_rate=False)
    base = normalize_price(p.get("base_recurring"), currencies, f"plan {name} base_recurring", is_rate=False)
    usages = p.get("usage", []) or []

    x.open("plan", name=name)
    x.leaf("product", product)

    # initial phases: a free TRIAL if requested
    if trial_days and int(trial_days) > 0:
        x.open("initialPhases")
        x.open("phase", type="TRIAL")
        x.open("duration")
        x.leaf("unit", "DAYS")
        x.leaf("number", str(int(trial_days)))
        x.close("duration")
        x.open("fixed")
        emit_prices(x, "fixedPrice", {c: "0" for c in currencies})  # free trial
        x.close("fixed")
        x.close("phase")
        x.close("initialPhases")
    else:
        x.leaf("initialPhases")  # empty <initialPhases/>

    # final phase: EVERGREEN with one-time setup (fixed) + base (recurring) + usage
    x.open("finalPhase", type="EVERGREEN")
    x.open("duration")
    x.leaf("unit", "UNLIMITED")
    x.close("duration")

    x.comment("setup fee: one-time, charged once on entering EVERGREEN; override per subscription")
    x.open("fixed")
    emit_prices(x, "fixedPrice", setup)
    x.close("fixed")

    x.comment("base maintenance: per period; override per subscription")
    x.open("recurring")
    x.leaf("billingPeriod", bp)
    emit_prices(x, "recurringPrice", base)
    x.close("recurring")

    if usages:
        x.open("usages")
        for u in usages:
            u = dict(u)
            u.setdefault("billing_period", bp)  # usage period defaults to plan period
            emit_usage(x, u, currencies)
        x.close("usages")

    x.close("finalPhase")
    x.close("plan")


def build_catalog(cfg):
    cat = cfg["catalog"]
    currencies = cfg.get("currencies") or []
    if not currencies:
        raise CatalogError("`currencies` must list at least one currency")
    for c in currencies:
        if not re.match(r"^[A-Z]{3}$", str(c)):
            raise CatalogError(f"currency {c!r} should be a 3-letter ISO code, e.g. KES")
    units = cfg.get("units") or []
    plans = cfg.get("plans") or []
    if not plans:
        raise CatalogError("no plans defined")
    default_trial = (cfg.get("defaults") or {}).get("trial_days", 0)

    # derive products from plans (category BASE)
    products = []
    seen = set()
    for p in plans:
        prod = check_name(p["product"], "product")
        if prod not in seen:
            seen.add(prod)
            products.append(prod)

    x = X()
    x.lines.append('<?xml version="1.0" encoding="UTF-8" standalone="no"?>')
    x.lines.append("<!-- GENERATED by generate.py from prices.yml. Do not edit by hand;"
                   " edit prices.yml and regenerate. -->")
    x.open("catalog",
           **{"xmlns:xsi": "http://www.w3.org/2001/XMLSchema-instance",
              "xsi:noNamespaceSchemaLocation": "CatalogSchema.xsd"})
    x.leaf("effectiveDate", cat["effective_date"])
    x.leaf("catalogName", check_name(cat["name"], "catalog"))
    x.leaf("recurringBillingMode", cat.get("recurring_billing_mode", "IN_ADVANCE"))

    x.open("currencies")
    for c in currencies:
        x.leaf("currency", c)
    x.close("currencies")

    if units:
        x.open("units")
        for u in units:
            x.leaf("unit", "", name=check_name(u, "unit"))
        x.close("units")

    x.open("products")
    for prod in products:
        x.open("product", name=prod)
        x.leaf("category", "BASE")
        x.close("product")
    x.close("products")

    # Minimal sensible rules: immediate plan changes, immediate cancel, DEFAULT price list.
    x.open("rules")
    x.open("changePolicy")
    x.open("changePolicyCase")
    x.leaf("policy", "IMMEDIATE")
    x.close("changePolicyCase")
    x.close("changePolicy")
    x.open("cancelPolicy")
    x.open("cancelPolicyCase")
    x.leaf("policy", "IMMEDIATE")
    x.close("cancelPolicyCase")
    x.close("cancelPolicy")
    x.close("rules")

    x.open("plans")
    for p in plans:
        emit_plan(x, p, currencies, default_trial)
    x.close("plans")

    x.open("priceLists")
    x.open("defaultPriceList", name="DEFAULT")
    x.open("plans")
    for p in plans:
        x.leaf("plan", p["name"])
    x.close("plans")
    x.close("defaultPriceList")
    x.close("priceLists")

    x.close("catalog")
    return x.render()


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    src = argv[1]
    out = None
    validate_only = "--validate-only" in argv
    for a in argv[2:]:
        if not a.startswith("--"):
            out = a

    with open(src) as f:
        cfg = yaml.safe_load(f)

    try:
        xml_text = build_catalog(cfg)
    except CatalogError as e:
        sys.exit(f"catalog error: {e}")

    # well-formedness self-check
    try:
        ET.fromstring(xml_text)
    except ET.ParseError as e:
        sys.exit(f"internal error: generated XML is not well-formed: {e}")

    n_plans = len(cfg.get("plans", []))
    n_cur = len(cfg.get("currencies", []))
    print(f"ok: catalog '{cfg['catalog']['name']}' — {n_plans} plan(s), {n_cur} currency(ies), well-formed.",
          file=sys.stderr)

    if validate_only:
        return
    if out:
        import os
        os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
        with open(out, "w") as f:
            f.write(xml_text)
        print(f"wrote {out}", file=sys.stderr)
    else:
        sys.stdout.write(xml_text)


if __name__ == "__main__":
    main(sys.argv)
