-- 02-reference-data.sql: lookup rows the system needs to work.
-- Adding a new material category, unit or storage kind is a new row here, not a schema change.

INSERT INTO materials (name) VALUES
('DNA'),
('Samples'),
('Target proteins'),
('Buffers'),
('Consumables'),
('Other materials');

INSERT INTO units (code, dimension, to_base) VALUES
('uL',  'volume', 1),
('mL',  'volume', 1000),
('L',   'volume', 1000000),
('ng',  'mass',   0.001),
('ug',  'mass',   1),
('mg',  'mass',   1000),
('g',   'mass',   1000000),
('pcs', 'count',  1);

-- max_children values are placeholders; real numbers depend on the lab's equipment.
INSERT INTO storage_unit_kinds (code, description, has_grid, max_children) VALUES
('room',       'Lab room',                       FALSE, NULL),
('freezer',    'Freezer (-20 / -80)',            FALSE, NULL),
('fridge',     'Fridge (4 C)',                   FALSE, NULL),
('shelf',      'Shelf',                          FALSE, NULL),
('bench',      'Bench workspace',                FALSE, NULL),
('instrument', 'Inside an instrument',           FALSE, NULL),
('rack',       'Freezer rack, holds boxes',      FALSE, 5),
('box',        'Tube box with grid positions',   TRUE,  NULL),
('plate',      'Well plate; each well a vessel', TRUE,  NULL);
