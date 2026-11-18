# Which installed modules does this Odoo carry at a version the database has
# not been upgraded to? Run it inside a container of the image to check, with
# apun's odoo.conf at /etc/odoo and the data volume at /var/lib/odoo:
#
#   kubectl -n apun exec <pod> -- python3 -I -c "$(cat docs/apun-image-change/module_check.py)"
#
# Read-only: one SELECT in a read-only session (the connection settings come
# from odoo.conf), and the manifests on Odoo's addons path, resolved the way
# the server resolves them (first match in addons path order, version with the
# "18.0." prefix added). Prints one UPGRADE line per module whose version
# differs, CHECK lines for anything else worth a look, and MODULES=<list>.
from odoo.tools import config
from odoo.modules import module as om
import psycopg2

config.parse_config(["--config=/etc/odoo/odoo.conf"], setup_logging=False)
conn = psycopg2.connect(
    dbname=config["db_name"].split(",")[0],
    options="-c default_transaction_read_only=on",
    **{k: config["db_" + k] for k in ("host", "port", "user", "password") if config["db_" + k]},
)
with conn.cursor() as cur:
    cur.execute("SELECT name, state, latest_version FROM ir_module_module"
                " WHERE state NOT IN ('uninstalled', 'uninstallable') ORDER BY name")
    rows = cur.fetchall()
conn.close()
upgrade = []
for name, state, db_version in rows:
    manifest = om.get_manifest(name)
    if not manifest:
        print(f"CHECK {name}: {state} in the database but not on the addons path")
        continue
    if state != "installed":
        print(f"CHECK {name}: state {state!r} in the database (an unfinished earlier run?)")
    if manifest["version"] != db_version:
        upgrade.append(name)
        print(f"UPGRADE {name}: database {db_version} -> files {manifest['version']} ({manifest['addons_path']})")
print(f"{len(rows)} modules checked")
print("MODULES=" + ",".join(upgrade))
