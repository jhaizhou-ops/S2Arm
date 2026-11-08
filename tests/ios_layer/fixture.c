static int result, reports;
void fixture_result(int value) { result = value; reports = 0; }
int fixture_reports(void) { return reports; }
int nxgal_window_attach_ios(void) { return result; }
void nxgal_window_attach_failed_ios(void) { reports++; }
