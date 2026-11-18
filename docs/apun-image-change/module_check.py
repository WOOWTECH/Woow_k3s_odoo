# Which installed modules does this Odoo carry at a version the database has
# not been upgraded to? Run it inside a container of the image to check, with
# apun's odoo.conf at /etc/odoo and the data volume at /var/lib/odoo:
#
#   kubectl -n apun exec <pod> -- python3 -I -c "$(cat docs/apun-image-change/module_check.py)"
#
# Read-only: one SELECT in a read-only session (the connection settings come
# from odoo.conf), and the manifests on Odoo's addons path, resolved the way
# the server resolves them (first match in addons path order, version with the
# "18.0." prefix added). For each module whose version differs it prints an
# UPGRADE line when the files come from the image, or a VOLUME line when they
# lie on the data volume (not the image's, and not part of an image change).
# CHECK lines are anything else worth a look. Then DATA_VOLUME_ONLY=<the VOLUME
# modules> and, last, MODULES=<the UPGRADE modules>, the list for the -u Job.
import os
from odoo.tools import config
from odoo.modules import module as om
import psycopg2

DATA_VOLUME = os.path.realpath("/var/lib/odoo")  # the data volume's mountPath
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
upgrade, volume = [], []
for name, state, db_version in rows:
    manifest = om.get_manifest(name)
    if not manifest:
        print(f"CHECK {name}: {state} in the database but not on the addons path")
        continue
    if state != "installed":
        print(f"CHECK {name}: state {state!r} in the database (an unfinished earlier run?)")
    if manifest["version"] != db_version:
        path = os.path.realpath(manifest["addons_path"])
        on_volume = os.path.commonpath([path, DATA_VOLUME]) == DATA_VOLUME
        (volume if on_volume else upgrade).append(name)
        print(f"{'VOLUME' if on_volume else 'UPGRADE'} {name}: database {db_version}"
              f" -> files {manifest['version']} ({manifest['addons_path']})")
print(f"{len(rows)} modules checked")
print("DATA_VOLUME_ONLY=" + ",".join(volume))
print("MODULES=" + ",".join(upgrade))
