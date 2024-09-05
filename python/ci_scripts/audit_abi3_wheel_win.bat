set WHEEL=%~1
rem we expect abi3audit to have a non-zero exit code
abi3audit --strict --report %WHEEL% > abi3audit_report.json
python ./scripts/check_abi3audit.py abi3audit_report.json
