async def test_health_reports_schema_loaded(client):
    r = await client.get("/health")
    assert r.status_code == 200
    assert r.json() == {"database": "ok", "schema_loaded": True, "schemas": ["audit", "inventory"]}
