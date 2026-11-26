"""End-to-end tests through the HTTP API. Each test builds a small lab via the API itself:

    ROOM-1 > FRZ-1 > TUBE-1 (1 mL target, lot T-778)
                   > SRC (plate)  wells A1, A2, A3: 100 uL target each (via POST /transfers)
                   > DST (plate)  no wells yet
"""

import pytest


async def post(client, url, body=None, status=None, **kw):
    r = await client.post(url, json=body, **kw)
    if status is not None:
        assert r.status_code == status, r.text
    return r.json()


@pytest.fixture
async def lab(client):
    await post(client, "/storage-units", {"barcode": "ROOM-1", "kind": "room"}, 201)
    await post(client, "/storage-units", {"barcode": "FRZ-1", "kind": "freezer", "stored_in": "ROOM-1"}, 201)
    for plate in ("SRC", "DST"):
        await post(client, "/storage-units",
                   {"barcode": plate, "kind": "plate", "stored_in": "FRZ-1", "n_rows": 8, "n_cols": 12}, 201)

    lot = await post(client, "/lots", {"material": 3, "supplier": "AcroBio", "supplier_lot_number": "T-778"}, 201)
    tube = await post(client, "/vessels", {"name": "target tube", "barcode": "TUBE-1", "stored_in": "FRZ-1",
                                           "max_volume_ul": 1500}, 201)
    target = await post(client, "/items", {"material": 3, "vessel_id": tube["id"], "quantity": 1, "unit": "mL",
                                           "lot_id": lot["id"]}, 201)

    wells = {}
    for pos in ("A1", "A2", "A3"):
        well = await post(client, "/vessels", {"name": "well", "stored_in": "SRC", "position": pos,
                                               "max_volume_ul": 200}, 201)
        moved = await post(client, "/transfers", {"parent_item": target["item_id"], "amount": 100, "unit": "uL",
                                                  "to_vessel_id": well["id"]}, 201)
        wells[pos] = moved["child_item"]
    return {"lot": lot["id"], "tube": tube["id"], "target": target["item_id"], "wells": wells}


# --- single transfer ---------------------------------------------------------

async def test_transfer_updates_parent_and_item_shows_status_and_location(client, lab):
    item = (await client.get(f"/items/{lab['target']}")).json()
    assert float(item["quantity"]) == 0.7                   # 1 mL - 3 x 100 uL
    assert item["light"] == "yellow" and item["yellow_reasons"] == ["qc_pending"]
    assert item["location"] == "ROOM-1 > FRZ-1"


async def test_transfer_rule_failure_is_422_with_database_reason(client, lab):
    r = await client.post("/transfers", json={"parent_item": lab["target"], "amount": 5, "unit": "mL",
                                              "to_vessel_id": lab["tube"]})
    assert r.status_code == 422
    assert "has only" in r.json()["error"]


async def test_transfer_needs_exactly_one_target(client, lab):
    r = await client.post("/transfers", json={"parent_item": lab["target"], "amount": 1, "unit": "uL"})
    assert r.status_code == 422   # rejected by the request model, before the database


# --- plate transfers ---------------------------------------------------------

async def test_plate_transfer_applies_every_well(client, lab):
    r = await client.post("/plates/SRC/transfer", json={"to_plate": "DST", "amount": 20})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["applied"] and [l["well"] for l in body["lines"]] == ["A1", "A2", "A3"]

    wells = (await client.get("/plates/DST")).json()["wells"]
    assert [(w["position"], float(w["total_volume_ul"])) for w in wells] == [("A1", 20), ("A2", 20), ("A3", 20)]


async def test_plate_transfer_dry_run_changes_nothing(client, lab):
    r = await client.post("/plates/SRC/transfer", json={"to_plate": "DST", "amount": 20, "dry_run": True})
    assert r.status_code == 200
    assert r.json()["dry_run"] and r.json()["would_succeed"] and not r.json()["applied"]
    assert (await client.get("/plates/DST")).json()["wells"] == []          # not even the wells were kept
    src = (await client.get("/plates/SRC/wells/A1")).json()
    assert float(src["total_volume_ul"]) == 100


@pytest.fixture
async def failed_plate_run(client, lab):
    """A2 only has 40 uL left, so a 50 uL plate transfer fails on A2 only."""
    other = await post(client, "/vessels", {"name": "spare", "stored_in": "FRZ-1", "max_volume_ul": 200}, 201)
    await post(client, "/transfers", {"parent_item": lab["wells"]["A2"], "amount": 60, "unit": "uL",
                                      "to_vessel_id": other["id"]}, 201)
    r = await client.post("/plates/SRC/transfer", json={"to_plate": "DST", "amount": 50})
    assert r.status_code == 202, r.text
    return r.json()


async def test_failed_plate_transfer_applies_nothing_and_files_the_batch(client, lab, failed_plate_run):
    body = failed_plate_run
    assert not body["applied"] and body["filed_batch"]
    assert [(l["well"], l["ok"]) for l in body["lines"]] == [("A1", True), ("A2", False), ("A3", True)]
    assert "has only 40" in body["lines"][1]["error"]

    a1 = (await client.get("/plates/SRC/wells/A1")).json()
    assert float(a1["total_volume_ul"]) == 100                               # A1 would have worked, but wasn't applied
    assert a1["item"]["yellow_reasons"] == ["qc_pending", "pending_review"]

    pending = (await client.get("/batches", params={"pending": True})).json()
    assert [b["id"] for b in pending] == [body["filed_batch"]]


async def test_fix_a_line_then_apply(client, lab, failed_plate_run):
    batch = failed_plate_run["filed_batch"]
    r = await client.patch(f"/batches/{batch}/lines/2", json={"amount": 40})
    assert r.status_code == 200, r.text

    r = await client.post(f"/batches/{batch}/apply", json={"note": "A2 had 40 uL, corrected"})
    assert r.status_code == 200, r.text

    wells = (await client.get("/plates/DST")).json()["wells"]
    assert [float(w["total_volume_ul"]) for w in wells] == [50, 40, 50]
    a1 = (await client.get("/plates/SRC/wells/A1")).json()
    assert "pending_review" not in a1["item"]["yellow_reasons"]              # flag cleared on apply


async def test_apply_without_fix_fails_and_batch_stays_pending(client, lab, failed_plate_run):
    batch = failed_plate_run["filed_batch"]
    r = await client.post(f"/batches/{batch}/apply")
    assert r.status_code == 422
    assert r.json()["error"].startswith(f"Batch {batch}, line 2:")
    assert (await client.get(f"/batches/{batch}")).json()["applied"] is False


async def test_reject_clears_flags(client, lab, failed_plate_run):
    batch = failed_plate_run["filed_batch"]
    assert (await client.post(f"/batches/{batch}/reject", json={"note": "run aborted"})).status_code == 200
    a1 = (await client.get("/plates/SRC/wells/A1")).json()
    assert a1["item"]["yellow_reasons"] == ["qc_pending"]
    assert (await client.post(f"/batches/{batch}/reject")).status_code == 422   # already resolved


# --- lots, scanning, reports, audit ------------------------------------------

async def test_failed_qc_turns_everything_from_the_lot_red(client, lab):
    await post(client, f"/lots/{lab['lot']}/qc", {"result": "failed"}, 200)
    trace = (await client.get(f"/lots/{lab['lot']}/trace")).json()["items"]
    assert len(trace) == 4                                                    # tube + 3 wells
    assert all(i["light"] == "red" and "qc_failed" in i["red_reasons"] for i in trace)


async def test_scan(client, lab):
    tube = (await client.get("/scan/TUBE-1")).json()
    assert tube["type"] == "vessel" and tube["location"] == "ROOM-1 > FRZ-1"
    assert tube["item"]["item_id"] == lab["target"]
    assert (await client.get("/scan/SRC")).json()["type"] == "storage_unit"
    assert (await client.get("/scan/NOPE")).status_code == 404


async def test_material_quantities(client, lab):
    rows = (await client.get("/reports/material-quantities")).json()
    targets = [r for r in rows if r["material"] == "Target proteins"]
    assert sum(float(r["total_base_unit"]) for r in targets) == 1000         # nothing lost: 700 + 3 x 100


async def test_audit_records_plate_transfer_context(client, lab):
    await post(client, "/plates/SRC/transfer", {"to_plate": "DST", "amount": 20}, 200)
    changes = (await client.get(f"/audit/inventory.items/{lab['wells']['A1']}")).json()["changes"]
    assert changes[-1]["context"] == "plate transfer SRC -> DST, 20 uL x 3 wells"
    assert changes[-1]["changed_columns"] == ["quantity", "updated_at"]
