"""
Applet: Costco Gas
Summary: Costco Gas Display
Description: Displays gas prices from a selected Costco warehouse in the US.
Author: Dan Adam
"""
# Revised: 2026-08-03
# Thanks: Portions of the code were adapted from the sf_next_muni applet written by Martin Strauss
# Attribution: Gas Icon from "https://www.iconfinder.com/icons/111078/gas_icon", Costco Icon from "https://play-lh.googleusercontent.com/gqOziTbVWioRJtHh7OvfOq07NCTcAHKWBYPQKJOZqNcczpOz5hdrnQNY7i2OatJxmuY=w240-h480-rw"

load("encoding/json.star", "json")
load("http.star", "http")
load("humanize.star", "humanize")
load("images/costco.png", COSTCO_ICON_ASSET = "file")
load("images/gas.png", GAS_ICON_ASSET = "file")
load("re.star", "re")
load("render.star", "render")
load("schema.star", "schema")
load("time.star", "time")

DEFAULT_CONFIG = {
    "warehouse": "1216",
    "price_colour": "white",
    "icon_display": "costco-icon",
    "time_format": "24-hours",
    "show_hours": False,
}

ICONS = {
    "gas-icon": GAS_ICON_ASSET.readall(),
    "costco-icon": COSTCO_ICON_ASSET.readall(),
}

PRICE_COLOURS = {
    "white": {
        "petrolColour": "#FFFFFF",
        "dieselColour": "#FFFFFF",
    },
    "red-green": {
        "petrolColour": "#ff0000",
        "dieselColour": "#00FF00",
    },
    "green-red": {
        "petrolColour": "#00FF00",
        "dieselColour": "#ff0000",
    },
}

# The locator API numbers weekdays Sunday-first, matching this map.
WEEKDAY_NUMBERS = {
    "Sun": "1",
    "Mon": "2",
    "Tue": "3",
    "Wed": "4",
    "Thu": "5",
    "Fri": "6",
    "Sat": "7",
}

# The trailing character is trimmed after formatting, so 12-hour times render as "6:00a".
TIME_FORMAT_MAP = {
    "24-hours": "15:04 ",
    "12-hours": "3:04pm",
}

CLOCK_FORMAT = "2006-01-02 15:04"
DATE_FORMAT = "2006-01-02"

HOURS_FONT = "tom-thumb"
OPEN_COLOUR = "#04AF45"
ALERT_COLOUR = "#C90000"
WAREHOUSE_COLOUR = "#0073A6"

# Costco's CDN drops requests that lack a browser User-Agent, so this one is required rather than
# cosmetic. Accept-Encoding is deliberately left unset: pixlet's HTTP client then negotiates gzip and
# transparently decompresses, which takes the warehouse search response from 225 KB to about 11 KB.
# Setting it to "identity" (as this app used to) is passed through verbatim and disables that.
API_HEADERS = {
    "Accept": "*/*",
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)",  # Only product directive is needed, others can be stripped
}

# The locator API additionally requires a public client id embedded in costco.com's own frontend.
# Its gateway validates the id against an allowlist of Costco's registered clients rather than
# binding one id to one service, so any of these is accepted and the later entries act as a fallback
# if the locator's own id is retired. A rejected id returns HTTP 401.
LOCATOR_CLIENT_IDS = [
    "7c71124c-7bf1-44db-bc9d-498584cd66e5",  # costco.com warehouse locator
    "481b1aec-aa3b-454b-b81b-48187e28f205",  # costco.com inventory / membership services
]

# Costco is migrating off its legacy WebSphere Commerce "Ajax*" command surface onto
# ecom-api.costco.com. AjaxWarehouseBrowseLookupView and AjaxWarehouseUpdateCmd are already blocked
# at the CDN edge (HTTP 403), which is what broke this app. AjaxGetGasPricesService is the last piece
# still served off the old stack and is the likely next casualty: if prices start failing, expect a
# replacement under ecom-api.costco.com/core/... gated by a client-identifier header, the same way
# warehouse listings moved.
#
# The two surviving endpoints split the data between them. The locator API searches only by
# coordinates, and the gas price service accepts only warehouse ids. Gas hours exist only in the
# locator response, so they are captured into the schema option value at configuration time.
API_WAREHOUSE_SEARCH = "https://ecom-api.costco.com/core/warehouse-locator/v1/warehouses.json?latitude={}&longitude={}&limit=50"
API_GAS_PRICES = "https://www.costco.com/AjaxGetGasPricesService?warehouseid={}"

# Both endpoints answer with "no-store" and neither sends an ETag or Last-Modified, so the CDN never
# serves them from edge cache and conditional requests are not possible: every request that misses
# reaches Costco's origin, and the price service opens a full commerce session on each call. pixlet's
# ttl_seconds cache overrides that no-store, which makes these TTLs the only thing limiting request
# volume rather than a nicety. The search is rounded to whole tenths of a degree for the same reason.
WAREHOUSE_SEARCH_TTL = 86400
GAS_PRICES_TTL = 3600

def get_schema():
    icons = [
        schema.Option(
            display = "Costco Logo",
            value = "costco-icon",
        ),
        schema.Option(
            display = "Gas Pump",
            value = "gas-icon",
        ),
    ]

    price_colours = [
        schema.Option(
            display = "White",
            value = "white",
        ),
        schema.Option(
            display = "Red Gas, Green Diesel",
            value = "red-green",
        ),
        schema.Option(
            display = "Green Gas, Red Diesel",
            value = "green-red",
        ),
    ]

    time_formats = [
        schema.Option(
            display = "24 Hour Clock",
            value = "24-hours",
        ),
        schema.Option(
            display = "12 Hour Clock",
            value = "12-hours",
        ),
    ]

    return schema.Schema(
        version = "1",
        fields = [
            schema.LocationBased(
                id = "warehouse_by_loc",
                name = "Warehouse",
                desc = "A list of warehouses by location",
                icon = "locationDot",
                handler = get_warehouses,
            ),
            schema.Toggle(
                id = "show_hours",
                name = "Show Hours",
                desc = "Show open hours for the current day. If enabled, icon won't show.",
                icon = "businessTime",
                default = DEFAULT_CONFIG["show_hours"],
            ),
            schema.Dropdown(
                id = "time_format",
                name = "Time Format",
                desc = "24 or 12 hour clock for hours display",
                icon = "clock",
                default = DEFAULT_CONFIG["time_format"],
                options = time_formats,
            ),
            schema.Dropdown(
                id = "icon_display",
                name = "Icon",
                desc = "Icon to display",
                icon = "icons",
                default = DEFAULT_CONFIG["icon_display"],
                options = icons,
            ),
            schema.Dropdown(
                id = "price_colour",
                name = "Price Colour",
                desc = "Colour scheme for price display",
                icon = "palette",
                default = DEFAULT_CONFIG["price_colour"],
                options = price_colours,
            ),
        ],
    )

def get_cached_json(url, headers, ttl):
    """Fetch and decode JSON, returning (status code, body); the body is None unless the call succeeded."""
    response = http.get(url, headers = headers, ttl_seconds = ttl)
    if response.status_code != 200:
        return response.status_code, None

    return response.status_code, response.json()

def get_locator_data(url, ttl):
    """Query the locator API, falling back to another client id if ours is rejected."""
    for client_id in LOCATOR_CLIENT_IDS:
        headers = dict(API_HEADERS)
        headers["client-identifier"] = client_id

        status, data = get_cached_json(url, headers, ttl)
        if data != None:
            return data

        # Only a rejected client id is worth retrying with a different one.
        if status != 401:
            return None

    return None

def get_localized_value(values):
    if type(values) != "list" or len(values) == 0:
        return ""

    return values[0].get("value", "")

def get_gas_service(warehouse):
    for service in warehouse.get("services", []):
        if service.get("code", "") == "gas":
            return service

    return None

def encode_gas_hours(hours):
    """Flatten the locator API's hours blocks into "<weekday>=<open>-<close>" pairs.

    The hours only reach main() through the saved schema option, so they are stored as a
    compact string rather than nested JSON.
    """
    encoded = []
    for block in hours:
        if block.get("hoursType", {}).get("code", "") != "open":
            continue

        opens = block.get("open", "")[:5]
        closes = block.get("close", "")[:5]
        if opens == "" or closes == "":
            continue

        for weekday in block.get("weekDays", []):
            encoded.append("%s=%s-%s" % (int(weekday), opens, closes))

    return ";".join(encoded)

def decode_gas_hours(encoded):
    gas_hours = {}
    for entry in encoded.split(";"):
        weekday, _, times = entry.partition("=")
        opens, _, closes = times.partition("-")
        if weekday != "" and opens != "" and closes != "":
            gas_hours[weekday] = {"open": opens, "closed": closes}

    return gas_hours

def get_warehouses(location):
    loc = json.decode(location)
    url = API_WAREHOUSE_SEARCH.format(
        humanize.float("#.#", float(loc["lat"])),
        humanize.float("#.#", float(loc["lng"])),
    )
    response = get_locator_data(url, WAREHOUSE_SEARCH_TTL)

    if response == None:
        return []

    options = []
    for warehouse in response.get("warehouses", []):
        gas_service = get_gas_service(warehouse)
        if gas_service == None:
            continue

        warehouse_id = warehouse.get("warehouseId", "")
        if warehouse_id == "":
            continue

        options.append(
            schema.Option(
                display = get_localized_value(warehouse.get("name", [])) + " #" + warehouse_id,
                value = warehouse_id + "|" + encode_gas_hours(gas_service.get("hours", [])),
            ),
        )

    return options

def get_warehouse_selection(config):
    """Read the saved warehouse, tolerating options saved before hours were encoded."""
    warehouse_id = DEFAULT_CONFIG["warehouse"]
    name = ""
    gas_hours = {}

    warehouse_cfg = config.get("warehouse_by_loc")
    if warehouse_cfg:
        selection = json.decode(warehouse_cfg)
        saved_id, _, encoded_hours = selection.get("value", "").partition("|")
        if saved_id != "":
            warehouse_id = saved_id
            name = selection.get("display", "")
            gas_hours = decode_gas_hours(encoded_hours)

    if name == "":
        name = "Costco #" + warehouse_id

    return warehouse_id, name, gas_hours

def get_gas_prices(warehouse_id):
    _, response = get_cached_json(API_GAS_PRICES.format(warehouse_id), API_HEADERS, GAS_PRICES_TTL)

    if response == None or type(response) != "dict":
        return None

    # The Ajax endpoints report failures as HTTP 200 with an {"errorMessage": ...} body, and return
    # an empty entry for a warehouse with no gas station, so an absent key is not an error here.
    return response.get(warehouse_id, {})

def hours_text(message, pad_left, colour = "#FFFFFF"):
    return render.Padding(
        child = render.Text(message, font = HOURS_FONT, color = colour),
        pad = (pad_left, 0, 0, 0),
    )

def get_gas_hours(gas_hours, config):
    timezone = time.tz()
    current_time = time.now().in_location(timezone)
    today = gas_hours.get(WEEKDAY_NUMBERS[current_time.format("Mon")], {})

    if not today:
        return [
            hours_text("Hours", 0, ALERT_COLOUR),
            hours_text("Unknown", 6, ALERT_COLOUR),
        ]

    current_date = current_time.format(DATE_FORMAT)
    opens = time.parse_time(current_date + " " + today["open"], CLOCK_FORMAT, timezone)
    closes = time.parse_time(current_date + " " + today["closed"], CLOCK_FORMAT, timezone)

    if current_time >= opens and current_time < closes:
        status = hours_text("OPEN", 18, OPEN_COLOUR)
    else:
        status = hours_text("CLOSED", 10, ALERT_COLOUR)

    # The format strings carry a trailing character that is trimmed to keep the times narrow.
    time_format = TIME_FORMAT_MAP[config.get("time_format", DEFAULT_CONFIG["time_format"])]

    return [status] + [hours_text(at.format(time_format)[:-1], 0) for at in [opens, closes]]

def get_hours_or_icon(gas_hours, config):
    render_children = []
    if config.bool("show_hours", DEFAULT_CONFIG["show_hours"]):
        render_children = get_gas_hours(gas_hours, config)
    else:
        render_children.append(
            render.Padding(
                child = render.Image(ICONS[config.get("icon_display", DEFAULT_CONFIG["icon_display"])], width = 20, height = 20),
                pad = (5, 0, 0, 0),
            ),
        )

    return render_children

def format_gas_price(gas_price):
    regex = r"^[\d]+\.\d\d9$"
    price_check = re.search(regex, gas_price)

    if price_check != None:
        return gas_price[:-1]

    return gas_price

def get_display(gas_prices, config):
    labels = []
    prices = []

    colours = PRICE_COLOURS[config.get("price_colour", DEFAULT_CONFIG["price_colour"])]

    for label, grade, colour in [
        ("R: ", "regular", colours["petrolColour"]),
        ("P: ", "premium", colours["petrolColour"]),
        ("D: ", "diesel", colours["dieselColour"]),
    ]:
        if gas_prices.get(grade, "") == "":
            continue

        labels.append(
            render.Text(label),
        )
        prices.append(
            render.Text(format_gas_price(gas_prices[grade]), color = colour),
        )

    return labels, prices

def main(config):
    warehouse_id, warehouse_name, gas_hours = get_warehouse_selection(config)
    gas_prices = get_gas_prices(warehouse_id)

    if gas_prices == None:
        return []

    labels, prices = get_display(gas_prices, config)

    if len(labels) == 0:
        body = render.Box(
            child = render.WrappedText("No gas prices", font = HOURS_FONT, color = ALERT_COLOUR, align = "center"),
        )
    else:
        body = render.Row(
            children = [
                render.Column(
                    children = labels,
                    cross_align = "start",
                ),
                render.Column(
                    children = prices,
                    cross_align = "end",
                ),
                render.Column(
                    children = get_hours_or_icon(gas_hours, config),
                    expanded = True,
                    main_align = "center",
                    cross_align = "end",
                ),
            ],
            expanded = True,
            main_align = "center",
            cross_align = "center",
        )

    return render.Root(
        child = render.Column(
            children = [
                render.Marquee(
                    width = 64,
                    child = render.Text(warehouse_name, color = WAREHOUSE_COLOUR),
                ),
                body,
            ],
        ),
    )
