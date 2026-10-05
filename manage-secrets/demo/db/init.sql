CREATE TABLE orders (
    id       serial PRIMARY KEY,
    customer text NOT NULL,
    item     text NOT NULL
);

INSERT INTO orders (customer, item) VALUES
    ('Alice', 'Croissant'),
    ('Bob',   'Sourdough'),
    ('Chloe', 'Cinnamon roll');
