-- ============================================================
-- HEALTHCARE ANALYTICS - STAR SCHEMA DDL
-- Database:  healthcare_dw (PostgreSQL on Neon)
-- Grain:     One row per encounter in fact_encounters

-- ============================================================
-- Schema Design:
--   8 Dimension tables → dim_date, dim_patient, dim_provider,
--                        dim_specialty, dim_department,
--                        dim_encounter_type, dim_diagnosis,
--                        dim_procedure
--   1 Fact table       → fact_encounters
--   2 Bridge tables    → bridge_encounter_diagnoses,
--                        bridge_encounter_procedures
-- ============================================================

-- ------------------------------------------------------------
-- DIMENSION: dim_date
-- ------------------------------------------------------------
-- Purpose: Pre-computed date attributes eliminate TO_CHAR()
--          function calls at query time. Proven in testing:
--          Hash Join time dropped from 45ms to 5ms for Q1.
-- Load:    One-time load using generate_series()
--          Never needs refresh unless fiscal calendar changes
-- ------------------------------------------------------------
CREATE TABLE dim_date (
    date_key        INT PRIMARY KEY,      
    calendar_date   DATE NOT NULL,        
    year            INT NOT NULL,         
    quarter         INT NOT NULL,         
    month           INT NOT NULL,         
    month_name      VARCHAR(20) NOT NULL, 
    week            INT NOT NULL,
    day_of_month    INT NOT NULL,         
    day_of_week     INT NOT NULL,         
    day_name        VARCHAR(20) NOT NULL, 
    is_weekend      BOOLEAN NOT NULL,     
    is_holiday      BOOLEAN DEFAULT FALSE,
    fiscal_year     INT,                  
    fiscal_quarter  INT                   
);

-- ------------------------------------------------------------
-- DIMENSION: dim_patient
-- ------------------------------------------------------------
-- Purpose: Stores patient demographic data with pre-computed
--          age_group to avoid age calculation at query time.
-- Load:    Daily refresh — SCD Type 1 (overwrite)
-- SCD:     Type 2 columns included for history tracking
-- ------------------------------------------------------------
CREATE TABLE dim_patient (
    patient_key     SERIAL PRIMARY KEY,   
    patient_id      INT NOT NULL,         
    mrn             VARCHAR(20),          
    first_name      VARCHAR(100),
    last_name       VARCHAR(100),
    full_name       VARCHAR(200),         
    gender          CHAR(1),              
    date_of_birth   DATE,
    age_group       VARCHAR(20),          
    is_current      BOOLEAN DEFAULT TRUE, 
    effective_date  DATE,                 
    expiry_date     DATE                  
);

CREATE INDEX idx_patient_id ON dim_patient(patient_id);

-- ------------------------------------------------------------
-- DIMENSION: dim_specialty
-- ------------------------------------------------------------
-- Purpose: Specialty reference dimension. specialty_key stored
--          directly on fact_encounters to eliminate JOIN chain:
--          encounters → providers → specialties (2 hops in OLTP)
--          Now: fact_encounters → dim_specialty (1 hop)
-- Load:    Weekly full refresh — small stable table
-- ------------------------------------------------------------
CREATE TABLE dim_specialty (
    specialty_key   SERIAL PRIMARY KEY,   
    specialty_id    INT NOT NULL,         
    specialty_name  VARCHAR(100),         
    specialty_code  VARCHAR(10)           
);

CREATE INDEX idx_specialty_id ON dim_specialty(specialty_id);

-- ------------------------------------------------------------
-- DIMENSION: dim_department
-- ------------------------------------------------------------
-- Purpose: Department reference dimension for filtering
--          encounters by hospital location.
-- Load:    Weekly full refresh — small stable table
-- ------------------------------------------------------------
CREATE TABLE dim_department (
    department_key  SERIAL PRIMARY KEY,
    department_id   INT NOT NULL,
    department_name VARCHAR(100),
    floor           INT,
    capacity        INT
);

CREATE INDEX idx_department_id ON dim_department(department_id);

-- ------------------------------------------------------------
-- DIMENSION: dim_provider
-- ------------------------------------------------------------
-- Purpose: DENORMALIZED dimension — specialty and department
--          info merged directly into provider record.
--          Eliminates providers → specialties JOIN at query time.
--          ETL does the join once during load; queries never need to.
-- Load:    Weekly refresh
-- ------------------------------------------------------------
CREATE TABLE dim_provider (
    provider_key        SERIAL PRIMARY KEY,   
    provider_id         INT NOT NULL,         
    first_name          VARCHAR(100),
    last_name           VARCHAR(100),
    full_name           VARCHAR(200),         
    credential          VARCHAR(20),          
    -- Denormalized from specialties table
    specialty_id        INT,
    specialty_name      VARCHAR(100),
    specialty_code      VARCHAR(10),
    -- Denormalized from departments table
    department_id       INT,
    department_name     VARCHAR(100),
    floor               INT
);

CREATE INDEX idx_provider_id ON dim_provider(provider_id);

-- ------------------------------------------------------------
-- DIMENSION: dim_encounter_type
-- ------------------------------------------------------------
-- Purpose: Low-cardinality dimension (3 values only).
--          Boolean flags is_inpatient and is_emergency enable
--          faster filtering than string comparison:
--          WHERE et.is_inpatient = TRUE  (boolean — fast)
--          vs WHERE encounter_type = 'Inpatient' (string — slow)
-- Load:    Manual only — static values never change
-- ------------------------------------------------------------
CREATE TABLE dim_encounter_type (
    encounter_type_key  SERIAL PRIMARY KEY,
    type_name           VARCHAR(50) NOT NULL, 
    is_inpatient        BOOLEAN,              
    is_emergency        BOOLEAN               
);

-- ------------------------------------------------------------
-- DIMENSION: dim_diagnosis
-- ------------------------------------------------------------
-- Purpose: ICD10 diagnosis code reference.
--          Used via bridge table for many-to-many relationship.
--          Kept separate to avoid row explosion in fact table.
-- Load:    Weekly full refresh
-- ------------------------------------------------------------
CREATE TABLE dim_diagnosis (
    diagnosis_key       SERIAL PRIMARY KEY,
    diagnosis_id        INT NOT NULL,         
    icd10_code          VARCHAR(10),          
    icd10_description   VARCHAR(200),         
    diagnosis_category  VARCHAR(100)          

CREATE INDEX idx_diagnosis_id ON dim_diagnosis(diagnosis_id);

-- ------------------------------------------------------------
-- DIMENSION: dim_procedure
-- ------------------------------------------------------------
-- Purpose: CPT procedure code reference.
--          Used via bridge table for many-to-many relationship.
-- Load:    Weekly full refresh
-- ------------------------------------------------------------
CREATE TABLE dim_procedure (
    procedure_key       SERIAL PRIMARY KEY,
    procedure_id        INT NOT NULL,         
    cpt_code            VARCHAR(10),          
    cpt_description     VARCHAR(200),         
    procedure_category  VARCHAR(100)          
);

CREATE INDEX idx_procedure_id ON dim_procedure(procedure_id);

-- ------------------------------------------------------------
-- FACT TABLE: fact_encounters
-- ------------------------------------------------------------
-- Purpose: Central fact table. Grain = ONE ROW PER ENCOUNTER.
--          Pre-aggregated metrics stored directly to avoid
--          expensive joins and calculations at query time.
--
-- Pre-aggregated metrics and their impact:
--   total_allowed_amount → eliminates billing JOIN (Q4: 2.8x faster)
--   diagnosis_count      → eliminates bridge JOIN for counts
--   procedure_count      → eliminates bridge JOIN for counts
--   length_of_stay_days  → eliminates date arithmetic at query time
--   is_readmission       → eliminates O(n²) self-join (Q3: 40x at scale)
--
-- Load:    Daily incremental — new encounters only
-- ------------------------------------------------------------
CREATE TABLE fact_encounters (
    -- Surrogate key
    encounter_fact_key      SERIAL PRIMARY KEY,

    -- Dimension foreign keys (all indexed integers — fast joins)
    encounter_date_key      INT NOT NULL,     
    discharge_date_key      INT,              
    patient_key             INT NOT NULL,     
    provider_key            INT NOT NULL,     
    specialty_key           INT NOT NULL,     
    department_key          INT NOT NULL,     
    encounter_type_key      INT NOT NULL,   

    -- Degenerate dimension (natural key kept for reference)
    encounter_id            INT NOT NULL,     

    -- Pre-aggregated billing metrics
    total_claim_amount      DECIMAL(12,2),    
    total_allowed_amount    DECIMAL(12,2),    
    claim_status            VARCHAR(50),      

    -- Pre-aggregated clinical metrics
    diagnosis_count         INT DEFAULT 0,    
    procedure_count         INT DEFAULT 0,    
    length_of_stay_days     INT DEFAULT 0,    

    -- Pre-computed analytical flags
    is_readmission          BOOLEAN DEFAULT FALSE, 

    -- Foreign key constraints
    FOREIGN KEY (encounter_date_key)  REFERENCES dim_date(date_key),
    FOREIGN KEY (patient_key)         REFERENCES dim_patient(patient_key),
    FOREIGN KEY (provider_key)        REFERENCES dim_provider(provider_key),
    FOREIGN KEY (specialty_key)       REFERENCES dim_specialty(specialty_key),
    FOREIGN KEY (department_key)      REFERENCES dim_department(department_key),
    FOREIGN KEY (encounter_type_key)  REFERENCES dim_encounter_type(encounter_type_key)
);

-- Indexes for common query patterns
CREATE INDEX idx_fact_encounter_date  ON fact_encounters(encounter_date_key);
CREATE INDEX idx_fact_patient         ON fact_encounters(patient_key);
CREATE INDEX idx_fact_provider        ON fact_encounters(provider_key);
CREATE INDEX idx_fact_specialty       ON fact_encounters(specialty_key);
CREATE INDEX idx_fact_encounter_id    ON fact_encounters(encounter_id);
CREATE INDEX idx_fact_readmission     ON fact_encounters(is_readmission);

-- ------------------------------------------------------------
-- BRIDGE TABLE: bridge_encounter_diagnoses
-- ------------------------------------------------------------
-- Purpose: Handles many-to-many relationship between
--          fact_encounters and dim_diagnosis.
--          One encounter can have multiple diagnoses.
--          One diagnosis can appear in many encounters.
--          Keeps fact table grain clean at one row per encounter.
-- Load:    Daily incremental — follows fact table load
-- ------------------------------------------------------------
CREATE TABLE bridge_encounter_diagnoses (
    bridge_diag_key         SERIAL PRIMARY KEY,
    encounter_fact_key      INT NOT NULL,    
    diagnosis_key           INT NOT NULL,     
    diagnosis_sequence      INT,              
    is_primary_diagnosis    BOOLEAN,          

    FOREIGN KEY (encounter_fact_key) REFERENCES fact_encounters(encounter_fact_key),
    FOREIGN KEY (diagnosis_key)      REFERENCES dim_diagnosis(diagnosis_key)
);

CREATE INDEX idx_bridge_diag_encounter ON bridge_encounter_diagnoses(encounter_fact_key);
CREATE INDEX idx_bridge_diag_key       ON bridge_encounter_diagnoses(diagnosis_key);

-- ------------------------------------------------------------
-- BRIDGE TABLE: bridge_encounter_procedures
-- ------------------------------------------------------------
-- Purpose: Handles many-to-many relationship between
--          fact_encounters and dim_procedure.
--          One encounter can have multiple procedures.
--          One procedure can appear in many encounters.
-- Load:    Daily incremental — follows fact table load
-- ------------------------------------------------------------
CREATE TABLE bridge_encounter_procedures (
    bridge_proc_key         SERIAL PRIMARY KEY,
    encounter_fact_key      INT NOT NULL,     
    procedure_key           INT NOT NULL,     
    procedure_date_key      INT,              

    FOREIGN KEY (encounter_fact_key) REFERENCES fact_encounters(encounter_fact_key),
    FOREIGN KEY (procedure_key)      REFERENCES dim_procedure(procedure_key)
);

CREATE INDEX idx_bridge_proc_encounter ON bridge_encounter_procedures(encounter_fact_key);
CREATE INDEX idx_bridge_proc_key       ON bridge_encounter_procedures(procedure_key);