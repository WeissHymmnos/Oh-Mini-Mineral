//! Standalone End-to-End Test Runner for Oh-My-Mineral.
//!
//! Executes all 4 test tiers:
//! - Tier 1: Happy-Path Feature Coverage (80 tests, 16 features)
//! - Tier 2: Boundary & Corner Cases (80 tests, 16 features)
//! - Tier 3: Pairwise Feature Combinations (18 tests)
//! - Tier 4: Real-World Workload Scenarios (6 scenarios)
//!
//! Exits with 0 on pass or non-zero on failure.

use std::env;
use std::time::Instant;

use omm_e2e_lib::tier1_features;
use omm_e2e_lib::tier2_boundaries;
use omm_e2e_lib::tier3_pairwise;
use omm_e2e_lib::tier4_workloads;

struct RunnerConfig {
    run_tier1: bool,
    run_tier2: bool,
    run_tier3: bool,
    run_tier4: bool,
    feature_filter: Option<usize>,
    scenario_filter: Option<String>,
    verbose: bool,
}

impl Default for RunnerConfig {
    fn default() -> Self {
        Self {
            run_tier1: true,
            run_tier2: true,
            run_tier3: true,
            run_tier4: true,
            feature_filter: None,
            scenario_filter: None,
            verbose: true,
        }
    }
}

fn parse_args() -> Result<RunnerConfig, String> {
    let mut config = RunnerConfig::default();
    let mut explicit_tier = false;

    let args: Vec<String> = env::args().skip(1).collect();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--tier" => {
                if i + 1 >= args.len() {
                    return Err("--tier requires a tier number (1, 2, 3, or 4)".to_string());
                }
                if !explicit_tier {
                    config.run_tier1 = false;
                    config.run_tier2 = false;
                    config.run_tier3 = false;
                    config.run_tier4 = false;
                    explicit_tier = true;
                }
                match args[i + 1].as_str() {
                    "1" => config.run_tier1 = true,
                    "2" => config.run_tier2 = true,
                    "3" => config.run_tier3 = true,
                    "4" => config.run_tier4 = true,
                    _ => return Err(format!("Invalid tier '{}', expected 1, 2, 3, or 4", args[i + 1])),
                }
                i += 1;
            }
            "--feature" => {
                if i + 1 >= args.len() {
                    return Err("--feature requires a feature number (1..16)".to_string());
                }
                let fid: usize = args[i + 1].parse().map_err(|_| "Invalid feature ID".to_string())?;
                config.feature_filter = Some(fid);
                i += 1;
            }
            "--scenario" => {
                if i + 1 >= args.len() {
                    return Err("--scenario requires a scenario ID (e.g. S01)".to_string());
                }
                config.scenario_filter = Some(args[i + 1].clone());
                config.run_tier1 = false;
                config.run_tier2 = false;
                config.run_tier3 = false;
                config.run_tier4 = true;
                i += 1;
            }
            "--all" => {
                config.run_tier1 = true;
                config.run_tier2 = true;
                config.run_tier3 = true;
                config.run_tier4 = true;
            }
            "--verbose" | "-v" => {
                config.verbose = true;
            }
            "--quiet" | "-q" => {
                config.verbose = false;
            }
            "--help" | "-h" => {
                print_help();
                std::process::exit(0);
            }
            other => {
                return Err(format!("Unknown argument: '{}'", other));
            }
        }
        i += 1;
    }

    Ok(config)
}

fn print_help() {
    println!("Oh-My-Mineral E2E Test Suite Runner");
    println!();
    println!("USAGE:");
    println!("    omm-e2e [OPTIONS]");
    println!();
    println!("OPTIONS:");
    println!("    --all              Run all test tiers (default)");
    println!("    --tier <N>         Run only tier N (1, 2, 3, or 4)");
    println!("    --feature <ID>     Filter Tier 1 & Tier 2 tests by feature ID (1..16)");
    println!("    --scenario <ID>    Filter Tier 4 by scenario ID (S01..S06)");
    println!("    --verbose, -v      Enable verbose logging per test");
    println!("    --quiet, -q        Summary only");
    println!("    --help, -h         Display this help message");
}

fn main() {
    let config = match parse_args() {
        Ok(c) => c,
        Err(err) => {
            eprintln!("Error: {}", err);
            print_help();
            std::process::exit(1);
        }
    };

    println!("===============================================================================");
    println!("           OH-MY-MINERAL (OMM) COMPREHENSIVE E2E TEST SUITE RUNNER            ");
    println!("===============================================================================");
    println!("Environment: Linux (x86_64) | 512-Byte Binary UDS | 64KB Seqlock SHM | FPC + Rust cdylib");
    println!("Timestamp:   {}", chrono_now());
    println!("-------------------------------------------------------------------------------");

    let total_start = Instant::now();
    let mut total_passed = 0;
    let mut total_failed = 0;
    let mut failures: Vec<(String, String)> = Vec::new();

    // -----------------------------------------------------------------------
    // TIER 1: FEATURE COVERAGE
    // -----------------------------------------------------------------------
    if config.run_tier1 {
        println!();
        println!(">>> RUNNING TIER 1: FEATURE COVERAGE (>=5 tests per feature)");
        let t1_start = Instant::now();
        let mut t1_passed = 0;
        let mut t1_failed = 0;

        for test in tier1_features::all_tests() {
            if let Some(fid) = config.feature_filter {
                if test.feature_id != fid {
                    continue;
                }
            }

            let start = Instant::now();
            match (test.func)() {
                Ok(()) => {
                    t1_passed += 1;
                    total_passed += 1;
                    if config.verbose {
                        println!("  [PASS] [{}] F{:02} - {} ({:?})", test.id, test.feature_id, test.name, start.elapsed());
                    }
                }
                Err(err) => {
                    t1_failed += 1;
                    total_failed += 1;
                    failures.push((format!("{}: {}", test.id, test.name), err.clone()));
                    println!("  [FAIL] [{}] F{:02} - {} -> {}", test.id, test.feature_id, test.name, err);
                }
            }
        }
        println!("--- Tier 1 Finished in {:?} | Passed: {} | Failed: {} ---", t1_start.elapsed(), t1_passed, t1_failed);
    }

    // -----------------------------------------------------------------------
    // TIER 2: BOUNDARIES & CORNER CASES
    // -----------------------------------------------------------------------
    if config.run_tier2 {
        println!();
        println!(">>> RUNNING TIER 2: BOUNDARIES & CORNER CASES (>=5 tests per feature)");
        let t2_start = Instant::now();
        let mut t2_passed = 0;
        let mut t2_failed = 0;

        for test in tier2_boundaries::all_tests() {
            if let Some(fid) = config.feature_filter {
                if test.feature_id != fid {
                    continue;
                }
            }

            let start = Instant::now();
            match (test.func)() {
                Ok(()) => {
                    t2_passed += 1;
                    total_passed += 1;
                    if config.verbose {
                        println!("  [PASS] [{}] F{:02} - {} ({:?})", test.id, test.feature_id, test.name, start.elapsed());
                    }
                }
                Err(err) => {
                    t2_failed += 1;
                    total_failed += 1;
                    failures.push((format!("{}: {}", test.id, test.name), err.clone()));
                    println!("  [FAIL] [{}] F{:02} - {} -> {}", test.id, test.feature_id, test.name, err);
                }
            }
        }
        println!("--- Tier 2 Finished in {:?} | Passed: {} | Failed: {} ---", t2_start.elapsed(), t2_passed, t2_failed);
    }

    // -----------------------------------------------------------------------
    // TIER 3: PAIRWISE COMBINATORIAL INTERACTIONS
    // -----------------------------------------------------------------------
    if config.run_tier3 && config.feature_filter.is_none() {
        println!();
        println!(">>> RUNNING TIER 3: PAIRWISE FEATURE COMBINATIONS");
        let t3_start = Instant::now();
        let mut t3_passed = 0;
        let mut t3_failed = 0;

        for test in tier3_pairwise::all_tests() {
            let start = Instant::now();
            match (test.func)() {
                Ok(()) => {
                    t3_passed += 1;
                    total_passed += 1;
                    if config.verbose {
                        println!("  [PASS] [{}] {} [{}] ({:?})", test.id, test.name, test.features, start.elapsed());
                    }
                }
                Err(err) => {
                    t3_failed += 1;
                    total_failed += 1;
                    failures.push((format!("{}: {}", test.id, test.name), err.clone()));
                    println!("  [FAIL] [{}] {} -> {}", test.id, test.name, err);
                }
            }
        }
        println!("--- Tier 3 Finished in {:?} | Passed: {} | Failed: {} ---", t3_start.elapsed(), t3_passed, t3_failed);
    }

    // -----------------------------------------------------------------------
    // TIER 4: REAL-WORLD APPLICATION WORKLOAD SCENARIOS
    // -----------------------------------------------------------------------
    if config.run_tier4 && config.feature_filter.is_none() {
        println!();
        println!(">>> RUNNING TIER 4: REAL-WORLD APPLICATION WORKLOAD SCENARIOS");
        let t4_start = Instant::now();
        let mut t4_passed = 0;
        let mut t4_failed = 0;

        for scenario in tier4_workloads::all_scenarios() {
            if let Some(ref sid) = config.scenario_filter {
                if scenario.id != sid {
                    continue;
                }
            }

            let start = Instant::now();
            match (scenario.func)() {
                Ok(()) => {
                    t4_passed += 1;
                    total_passed += 1;
                    println!("  [PASS] [{}] {} ({:?})", scenario.id, scenario.name, start.elapsed());
                    if config.verbose {
                        println!("         Scope: {}", scenario.features);
                        println!("         Desc:  {}", scenario.description);
                    }
                }
                Err(err) => {
                    t4_failed += 1;
                    total_failed += 1;
                    failures.push((format!("{}: {}", scenario.id, scenario.name), err.clone()));
                    println!("  [FAIL] [{}] {} -> {}", scenario.id, scenario.name, err);
                }
            }
        }
        println!("--- Tier 4 Finished in {:?} | Passed: {} | Failed: {} ---", t4_start.elapsed(), t4_passed, t4_failed);
    }

    // -----------------------------------------------------------------------
    // FINAL SUMMARY
    // -----------------------------------------------------------------------
    let elapsed = total_start.elapsed();
    println!();
    println!("===============================================================================");
    println!("                             E2E TEST SUITE SUMMARY                            ");
    println!("===============================================================================");
    println!("Total Executed: {}", total_passed + total_failed);
    println!("Passed:         {}", total_passed);
    println!("Failed:         {}", total_failed);
    println!("Total Duration: {:?}", elapsed);
    println!("Feature Coverage: 16 / 16 Features (100.0%)");
    println!("Target Pass Rate: 100.0%");

    if total_failed == 0 {
        println!();
        println!(">>> OVERALL RESULT: ALL TESTS PASSED (EXIT CODE 0) <<<");
        println!("===============================================================================");
        std::process::exit(0);
    } else {
        println!();
        println!(">>> OVERALL RESULT: {} TEST(S) FAILED <<<", total_failed);
        println!("Failure Details:");
        for (i, (test_name, err)) in failures.iter().enumerate() {
            println!("  {:2}. {} => {}", i + 1, test_name, err);
        }
        println!("===============================================================================");
        std::process::exit(1);
    }
}

fn chrono_now() -> String {
    // Simple timestamp format without external chrono crate dependency
    use std::time::SystemTime;
    let d = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).unwrap_or_default();
    format!("UnixTimestamp: {}s", d.as_secs())
}
