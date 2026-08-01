const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { chromium } = require('playwright');

async function main() {
  const root = __dirname;
  const sourceUrl = pathToFileURL(path.join(root, 'source.html')).href;
  const browser = await chromium.launch({
    executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    headless: true,
  });
  const page = await browser.newPage({
    viewport: { width: 2064, height: 2752 },
    deviceScaleFactor: 1,
  });

  const outputs = [
    '01-discover-ipad.png',
    '02-compare-ipad.png',
    '03-booking-ipad.png',
    '04-partner-ipad.png',
  ];

  for (let index = 0; index < outputs.length; index += 1) {
    await page.goto(`${sourceUrl}?screen=${index + 1}`, { waitUntil: 'load' });
    await page.waitForFunction(() =>
      [...document.images].every((image) => image.complete && image.naturalWidth > 0),
    );
    await page.screenshot({
      path: path.join(root, outputs[index]),
      type: 'png',
      animations: 'disabled',
    });
  }

  await browser.close();
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
