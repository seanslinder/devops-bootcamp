SELECT c.id, c.full_name, c.rank, s.name AS ship, s.class
FROM crew c
JOIN ships s ON s.id = c.ship_id
ORDER BY s.name, c.id;

SELECT s.name AS ship, COUNT(*) AS crew_count
FROM ships s
JOIN crew c ON c.ship_id = s.id
GROUP BY s.name;
