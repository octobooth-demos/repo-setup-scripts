We are missing any end to end tests. As such, we don't have an automated way to ensure everything is behaving correctly. Let's fix that by adding some Playwright tests.

## Requirements:

- Update the project to use Playwright
- Configure Playwright to use Chromium for testing
- Create Playwright tests for the core functionality of the website
- Ensure all tests pass
- Update package.json to add scripts to run the tests
- Create a new workflow to run the tests on PR or Merge into the main branch
