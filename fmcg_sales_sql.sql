-- Cơ bảnQ1: Tổng doanh thu thực 4 tháng 
SELECT COUNT(DISTINCT s.transaction_number) AS transactions,
	SUM(s.quantity) AS units_sold,
	CAST(SUM(s.quantity*p.price) AS DECIMAL(18,2)) AS revenue_before_discount,
	CAST(SUM(s.quantity*p.price*(1-s.discount)) AS DECIMAL(18,2)) AS revenue_after_discount,
	CAST(SUM(s.quantity*p.price*(1-s.discount)) / COUNT(DISTINCT s.transaction_number) AS DECIMAL(8,2)) AS aov
FROM fmcg_sales.sales s
JOIN fmcg_sales.products p ON s.product_id = p.product_id

--Nâng caoQ11: Doanh thu theo tháng + doanh thu tích luỹ 
WITH cte_revenue_month AS
(
SELECT 
    DATEFROMPARTS(YEAR(s.sales_date), MONTH(s.sales_date), 1) AS month_start,
    COUNT(*) AS transactions,
    SUM(s.quantity*p.price*(1-s.discount)) AS net_revenue
FROM fmcg_sales.sales s
JOIN fmcg_sales.products p ON s.product_id = p.product_id
GROUP BY DATEFROMPARTS(YEAR(s.sales_date), MONTH(s.sales_date), 1)
)

SELECT FORMAT(month_start, 'yyyy-MM') AS year_month,
    transactions,
    CAST(net_revenue AS DECIMAL(18,2)) AS net_revenue,
    CAST(SUM(net_revenue) OVER(
        ORDER BY month_start
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS DECIMAL(18,2)) AS cumulative_revenue
FROM cte_revenue_month
ORDER BY year_month

--- doanh thu theo tung thanh pho
SELECT  
    ci.city_name,
    CAST(SUM(s.quantity*p.price*(1-s.discount)) AS DECIMAL(18,2)) AS revenue
FROM fmcg_sales.sales s
JOIN fmcg_sales.products p ON s.product_id = p.product_id
JOIN fmcg_sales.customers cu ON s.customer_id = cu.customer_id
JOIN fmcg_sales.cities ci ON cu.city_id = ci.city_id
GROUP BY ci.city_id, ci.city_name
ORDER BY revenue DESC, ci.city_name


--Trung cấpQ8: Repeat customer vs One-time buyer 
WITH customer_activity AS (
    SELECT
        s.customer_id,
        COUNT(DISTINCT CAST(s.sales_date AS DATE)) AS shopping_days,
        COUNT(*) AS transactions,
        SUM(s.quantity * p.price * (1 - s.discount)) AS lifetime_value
    FROM fmcg_sales.sales s
    JOIN fmcg_sales.products p
        ON s.product_id = p.product_id
    GROUP BY s.customer_id
),
customer_segment AS (
    SELECT
        CASE
            WHEN shopping_days = 1 THEN 'One-time buyer'
            ELSE 'Repeat customer'
        END AS customer_type,
        lifetime_value
    FROM customer_activity
),
customer_types AS (
    SELECT 'One-time buyer' AS customer_type
    UNION ALL
    SELECT 'Repeat customer'
),
customer_summary AS (
    SELECT
        customer_type,
        COUNT(*) AS customers,
        SUM(lifetime_value) AS total_revenue,
        AVG(lifetime_value) AS avg_lifetime_value
    FROM customer_segment
    GROUP BY customer_type
)
SELECT
    t.customer_type,
    COALESCE(s.customers, 0) AS customers,

    CAST(
        COALESCE(s.customers, 0) * 100.0 /
        NULLIF(SUM(COALESCE(s.customers, 0)) OVER(), 0)
        AS DECIMAL(5,2)
    ) AS pct_of_customers,

    CAST(
        COALESCE(s.total_revenue, 0)
        AS DECIMAL(18,2)
    ) AS total_revenue,

    CAST(
        COALESCE(s.total_revenue, 0) * 100.0 /
        NULLIF(SUM(COALESCE(s.total_revenue, 0)) OVER(), 0)
        AS DECIMAL(5,2)
    ) AS pct_of_revenue,

    CAST(
        COALESCE(s.avg_lifetime_value, 0)
        AS DECIMAL(18,2)
    ) AS avg_lifetime_value

FROM customer_types t
LEFT JOIN customer_summary s ON t.customer_type = s.customer_type
ORDER BY t.customer_type;

--- RFM 

WITH cte_rfm AS
(
    SELECT
        s.customer_id,
        MAX(CAST(s.sales_date AS DATE)) AS last_date,
        DATEDIFF(
            DAY,
            MAX(CAST(s.sales_date AS DATE)),
            CAST('20180430' AS DATE)
        ) AS recency,
        COUNT(DISTINCT s.transaction_number) AS frequency,
        SUM(s.quantity * p.price * (1-s.discount)) AS monetary
    FROM fmcg_sales.sales s
    JOIN fmcg_sales.products p
        ON s.product_id = p.product_id
    WHERE s.sales_date >= '20180101'
      AND s.sales_date < '20180501'
      AND s.customer_id IS NOT NULL
    GROUP BY s.customer_id
),
cte_rfm_score AS
(
    SELECT
        customer_id,
        last_date,
        recency,
        frequency,
        monetary,
        5 - NTILE(4) OVER(ORDER BY recency ASC) AS r_score,
        5 - NTILE(4) OVER(ORDER BY frequency DESC) AS f_score,
        5 - NTILE(4) OVER(ORDER BY monetary DESC) AS m_score
    FROM cte_rfm
),
cte_total_score AS
(
    SELECT *,
        r_score + f_score + m_score AS rfm_score
    FROM cte_rfm_score
),
cte_segment AS
(
    SELECT *,
        NTILE(4) OVER(
            ORDER BY rfm_score DESC, customer_id
        ) AS customer_segment
    FROM cte_total_score
)
SELECT
    cte.customer_id,
    c.first_name + ' ' + c.last_name AS customer_name,
    cte.last_date,
    cte.recency,
    cte.frequency,
    CAST(cte.monetary AS DECIMAL(18,2)) AS monetary,
    cte.r_score,
    cte.f_score,
    cte.m_score,
    cte.rfm_score,
    CASE cte.customer_segment
        WHEN 1 THEN 'Champions'
        WHEN 2 THEN 'Loyal Customers'
        WHEN 3 THEN 'Potential Customers'
        WHEN 4 THEN 'Low Value Customers'
    END AS customer_group
FROM cte_segment cte
JOIN fmcg_sales.customers c
    ON c.customer_id = cte.customer_id
ORDER BY cte.rfm_score DESC, cte.customer_id;

--Trung cấpQ10: Sản phẩm zombie chưa từng bán 
WITH product_activity AS (
    SELECT
        p.product_id,
        p.product_name,
        cat.category_name,
        p.price, 
        (SELECT COUNT(*)  FROM fmcg_sales.sales s WHERE s.product_id = p.product_id) AS time_sold
    FROM fmcg_sales.products p 
    JOIN fmcg_sales.categories cat ON p.category_id = cat.category_id
)

SELECT TOP 10 product_id, product_name, category_name, CAST(price AS DECIMAL(8,2)) AS price, time_sold,
    CASE WHEN time_sold = 0 THEN 'zombie - chua tung ban' ELSE 'Co ban nhung cham nhat' END AS status,
    (SELECT COUNT(*) FROM product_activity WHERE time_sold = 0) AS zombie_count_total
FROM product_activity
ORDER BY time_sold, product_name

-- Cơ bảnQ2: Liệt kê ngành hàng + số SKU 
SELECT cat.category_id, cat.category_name,
	COUNT(*) AS sku_count,
	CAST(AVG(p.price) AS DECIMAL(12,2)) AS avg_price,
	CAST(MAX(p.price) AS DECIMAL(12,2)) AS max_price,
	CAST(MIN(p.price) AS DECIMAL(12,2)) AS min_price,
    CAST(SUM(s.quantity*p.price*(1-s.discount)) AS DECIMAL(18,2)) AS revenue_cat,
    ROW_NUMBER() OVER(
        ORDER BY SUM(s.quantity*p.price*(1-s.discount)) DESC
    ) AS rank
FROM fmcg_sales.products p
JOIN fmcg_sales.categories cat ON p.category_id = cat.category_id
JOIN fmcg_sales.sales s ON s.product_id = p.product_id
GROUP BY cat.category_id, cat.category_name
ORDER BY cat.category_name ASC

--- top 10 bán chạy nhất
SELECT TOP 10 p.product_id, p.product_name,
    SUM(s.quantity) AS quantity,
    CAST(SUM(s.quantity*p.price*(1-s.discount)) AS DECIMAL(18,2)) AS revenue_product
FROM fmcg_sales.products p
JOIN fmcg_sales.categories cat ON p.category_id = cat.category_id
JOIN fmcg_sales.sales s ON s.product_id = p.product_id
GROUP BY p.product_id, p.product_name
ORDER BY quantity DESC, p.product_name

--- top 10 bán ít nhất
SELECT TOP 10 p.product_id, p.product_name,
    SUM(s.quantity) AS quantity,
    CAST(SUM(s.quantity*p.price*(1-s.discount)) AS DECIMAL(18,2)) AS revenue_product
FROM fmcg_sales.products p
JOIN fmcg_sales.categories cat ON p.category_id = cat.category_id
JOIN fmcg_sales.sales s ON s.product_id = p.product_id
GROUP BY p.product_id, p.product_name
ORDER BY quantity ASC, p.product_name