"""Request bodies. Pydantic checks the SHAPE of a request (types, required fields, exactly one
target). Business rules (enough left, vessel capacity, red items, units) are checked by the
database, so they are NOT repeated here.

Bodies refer to vessels and items by id. Humans scan barcodes; GET /scan/{barcode} turns a
barcode into the record (and its id), which is how a UI or robot gets the id to send.
"""

from datetime import datetime
from decimal import Decimal
from typing import Literal

from pydantic import BaseModel, Field, model_validator


# --- Locations ---------------------------------------------------------------

class StorageUnitIn(BaseModel):
    barcode: str
    kind: str = Field(description="A storage_unit_kinds code: room, freezer, fridge, rack, box, plate, ...")
    stored_in: str | None = Field(None, description="Barcode of the parent unit; omit for a top-level place")
    description: str | None = None
    n_rows: int | None = Field(None, description="Grid rows, for plates and boxes (8 for a 96-well plate)")
    n_cols: int | None = Field(None, description="Grid columns (12 for a 96-well plate)")


class MoveIn(BaseModel):
    to: str = Field(description="Barcode of the storage unit to move into")


class VesselIn(BaseModel):
    name: str
    stored_in: str = Field(description="Barcode of the storage unit (for a well: the plate)")
    barcode: str | None = Field(None, description="Tubes have one; wells don't")
    position: str | None = Field(None, description="Grid slot, e.g. 'A1'")
    max_volume_ul: Decimal | None = None


# --- Lots and items ----------------------------------------------------------

class LotIn(BaseModel):
    material: int
    supplier: str
    supplier_lot_number: str
    certificate_of_analysis: str | None = None
    received_at: datetime | None = None


class QcIn(BaseModel):
    result: Literal["passed", "failed"]


class ItemIn(BaseModel):
    """Receive material into a vessel (a delivery, or something made outside transfer())."""
    material: int
    vessel_id: int
    quantity: Decimal = Field(ge=0)
    unit: str
    lot_id: int | None = Field(None, description="Supplier lot, for bought material")
    description: str | None = None
    expires_at: datetime | None = None


class FlagsIn(BaseModel):
    """Recorded yellow flags. Omitted fields are left unchanged."""
    reserved: bool | None = None
    in_use: bool | None = None
    in_transit: bool | None = None


# --- Transfers ---------------------------------------------------------------

class TransferIn(BaseModel):
    parent_item: int
    amount: Decimal = Field(gt=0)
    unit: str
    to_vessel_id: int | None = Field(None, description="Put it in this vessel (mixes if it already holds a liquid)")
    to_item_id: int | None = Field(None, description="Add it to this existing item (e.g. a buffer being made)")
    material: int | None = Field(None, description="Material of a new mixture; default: the parent's")

    @model_validator(mode="after")
    def exactly_one_target(self):
        if (self.to_vessel_id is None) == (self.to_item_id is None):
            raise ValueError("give exactly one of to_vessel_id or to_item_id")
        return self


class BatchLineIn(BaseModel):
    """One line of a batch. Deliberately NOT validated beyond types: a bad line must reach the
    database so it can be recorded with its reason, not rejected before anything is filed."""
    parent_item: int
    amount: Decimal
    unit: str
    to_vessel_id: int | None = None
    to_item_id: int | None = None


class BatchIn(BaseModel):
    lines: list[BatchLineIn] = Field(min_length=1)
    context: str | None = Field(None, description="What this action is, for the audit log")
    dry_run: bool = Field(False, description="Check every line, then roll everything back")


class PlateTransferIn(BaseModel):
    to_plate: str = Field(description="Barcode of the target plate")
    amount: Decimal = Field(gt=0)
    unit: str = "uL"
    wells: Literal["all"] | list[str] = Field("all", description="'all' wells with content, or a list like ['A1','B7']")
    dry_run: bool = False


class BatchLineFixIn(BaseModel):
    """Correct a line of a filed batch before applying it. Omitted fields are left unchanged."""
    parent_item: int | None = None
    amount: Decimal | None = None
    unit: str | None = None
    to_vessel_id: int | None = None
    to_item_id: int | None = None


class ResolveIn(BaseModel):
    note: str | None = None
