DROP TABLE IF EXISTS crew;
DROP TABLE IF EXISTS ships;

CREATE TABLE ships (
    id    SERIAL PRIMARY KEY,
    name  VARCHAR(50) NOT NULL UNIQUE,
    class VARCHAR(30)
);

CREATE TABLE crew (
    id        SERIAL PRIMARY KEY,
    full_name VARCHAR(80) NOT NULL,
    rank      VARCHAR(30) NOT NULL,
    ship_id   INTEGER REFERENCES ships(id),
    hired_at  DATE DEFAULT CURRENT_DATE
);
