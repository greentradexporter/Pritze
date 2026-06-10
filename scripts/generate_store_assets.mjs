import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const outDir = 'store_assets';
mkdirSync(outDir, { recursive: true });

const logo = readFileSync('assets/brand/pritze_icon_mark_transparent.png');
const logoHref = `data:image/png;base64,${logo.toString('base64')}`;

const colors = {
  ink: '#111827',
  muted: '#64748b',
  line: '#e5e7eb',
  canvas: '#f7f8fb',
  primary: '#0f766e',
  mint: '#dff7ef',
  coral: '#ef6a5b',
  amber: '#f5b84b',
  blue: '#2563eb',
  plum: '#7c3aed',
};

function esc(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
}

function text(x, y, value, size = 32, weight = 700, fill = colors.ink, anchor = 'start') {
  return `<text x="${x}" y="${y}" font-family="Inter, Arial, sans-serif" font-size="${size}" font-weight="${weight}" fill="${fill}" text-anchor="${anchor}">${esc(value)}</text>`;
}

function rounded(x, y, w, h, r = 28, fill = '#fff', stroke = colors.line, sw = 1) {
  return `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="${r}" fill="${fill}" stroke="${stroke}" stroke-width="${sw}"/>`;
}

function chip(x, y, label, fill = colors.mint, color = colors.primary, width = 150) {
  return `${rounded(x, y, width, 48, 24, fill, 'none', 0)}${text(x + width / 2, y + 31, label, 20, 800, color, 'middle')}`;
}

function logoMark(x, y, size, bg = '#fff') {
  return `${rounded(x, y, size, size, size * 0.24, bg, 'rgba(15,23,42,0.08)', 1)}
  <image href="${logoHref}" x="${x + size * 0.13}" y="${y + size * 0.13}" width="${size * 0.74}" height="${size * 0.74}" preserveAspectRatio="xMidYMid meet"/>`;
}

function phoneFrame(content, title, subtitle) {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="1080" height="1920" viewBox="0 0 1080 1920">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#f7faf8"/>
      <stop offset="1" stop-color="#edf5f1"/>
    </linearGradient>
    <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="18" stdDeviation="24" flood-color="#0f172a" flood-opacity="0.14"/>
    </filter>
  </defs>
  <rect width="1080" height="1920" fill="url(#bg)"/>
  <circle cx="940" cy="150" r="220" fill="#dff7ef"/>
  <circle cx="90" cy="1660" r="270" fill="#fff1d8"/>
  <rect x="90" y="80" width="900" height="1760" rx="58" fill="#111827" filter="url(#shadow)"/>
  <rect x="116" y="112" width="848" height="1696" rx="42" fill="#ffffff"/>
  <rect x="438" y="132" width="204" height="22" rx="11" fill="#111827"/>
  ${logoMark(154, 186, 78)}
  ${text(248, 235, 'Pritze', 42, 900)}
  ${text(154, 330, title, 50, 900)}
  ${text(154, 378, subtitle, 25, 600, colors.muted)}
  ${content}
  </svg>`;
}

function salonCard(x, y, name, service, price, slot, accent = colors.primary) {
  return `${rounded(x, y, 772, 220, 28, '#fff', '#e8edf1')}
  <circle cx="${x + 60}" cy="${y + 62}" r="34" fill="${accent}"/>
  ${text(x + 112, y + 58, name, 30, 900)}
  ${text(x + 112, y + 94, service, 22, 600, colors.muted)}
  ${chip(x + 112, y + 120, price, '#f8fafc', colors.ink, 120)}
  ${chip(x + 250, y + 120, slot, colors.mint, colors.primary, 190)}
  ${text(x + 650, y + 162, 'Book', 24, 900, accent)}
  <path d="M${x + 710} ${y + 154} l18 18 l-18 18" fill="none" stroke="${accent}" stroke-width="6" stroke-linecap="round" stroke-linejoin="round"/>`;
}

function discoverSvg() {
  const content = `
  ${rounded(154, 430, 772, 92, 28, '#f8fafc', '#edf2f7')}
  ${text(204, 488, 'Search salon, service, area', 26, 600, colors.muted)}
  ${chip(154, 558, 'Haircut', colors.mint, colors.primary, 150)}
  ${chip(326, 558, 'Beard', '#fff4df', '#9a5b00', 132)}
  ${chip(480, 558, 'Spa', '#f3e8ff', colors.plum, 100)}
  ${chip(602, 558, 'Color', '#eef2ff', colors.blue, 120)}
  ${salonCard(154, 660, 'Urban Trim Studio', 'Classic Haircut, Beard Trim', '₹250', '10:30 AM')}
  ${salonCard(154, 912, 'Crown & Comb', 'Signature Cut, Hair Color', '₹320', '12:00 PM', colors.coral)}
  ${salonCard(154, 1164, 'Fresh Fade Lounge', 'Skin Fade, Kids Cut', '₹300', '2:30 PM', colors.blue)}
  ${rounded(154, 1518, 772, 116, 34, colors.ink, 'none', 0)}
  ${text(200, 1586, 'Book grooming appointments without calling around', 28, 900, '#fff')}
  `;
  return phoneFrame(content, 'Find your next cut', 'Discover salons, services, barbers, and slots.');
}

function bookingSvg() {
  const content = `
  ${rounded(154, 430, 772, 230, 34, colors.ink, 'none', 0)}
  ${text(204, 502, 'Classic Haircut', 38, 900, '#fff')}
  ${text(204, 550, 'Urban Trim Studio', 26, 600, '#d1d5db')}
  ${chip(204, 586, '30 min', '#ffffff22', '#fff', 120)}
  ${chip(344, 586, '₹250', '#ffffff22', '#fff', 110)}
  ${text(154, 750, 'Choose barber', 34, 900)}
  ${rounded(154, 786, 772, 110, 28, '#fff', '#e8edf1')}
  ${text(206, 854, 'Any available', 28, 900)}
  ${chip(696, 817, 'Fastest slot', colors.mint, colors.primary, 166)}
  ${rounded(154, 924, 772, 110, 28, '#fff', '#e8edf1')}
  ${text(206, 992, 'Arjun Mane', 28, 900)}
  ${text(206, 1024, 'Fade specialist', 20, 600, colors.muted)}
  ${rounded(154, 1090, 772, 268, 34, '#f8fafc', '#e8edf1')}
  ${text(204, 1154, 'Available slots', 32, 900)}
  ${chip(204, 1198, '10:30 AM', colors.mint, colors.primary, 150)}
  ${chip(374, 1198, '11:00 AM', '#fff', colors.ink, 150)}
  ${chip(544, 1198, '12:30 PM', '#fff', colors.ink, 150)}
  ${chip(204, 1270, '2:00 PM', '#fff', colors.ink, 140)}
  ${chip(364, 1270, '4:30 PM', '#fff', colors.ink, 140)}
  ${rounded(154, 1518, 772, 116, 34, colors.primary, 'none', 0)}
  ${text(540, 1588, 'Book this slot', 30, 900, '#fff', 'middle')}
  `;
  return phoneFrame(content, 'Book in a few taps', 'Select service, barber, and appointment time.');
}

function ownerSvg() {
  const content = `
  ${rounded(154, 430, 772, 188, 34, colors.ink, 'none', 0)}
  ${text(204, 505, '₹4,850 collected', 42, 900, '#fff')}
  ${text(204, 552, '18 appointments today', 25, 600, '#d1d5db')}
  ${text(154, 704, 'Owner dashboard', 34, 900)}
  ${rounded(154, 742, 360, 150, 28, '#fff', '#e8edf1')}
  ${text(204, 804, 'Pending', 25, 700, colors.muted)}
  ${text(204, 854, '7', 50, 900, colors.amber)}
  ${rounded(566, 742, 360, 150, 28, '#fff', '#e8edf1')}
  ${text(616, 804, 'Completed', 25, 700, colors.muted)}
  ${text(616, 854, '11', 50, 900, colors.primary)}
  ${rounded(154, 934, 772, 270, 34, '#fff', '#e8edf1')}
  ${text(204, 1000, 'Chair board', 32, 900)}
  ${text(204, 1062, 'Arjun Mane', 26, 800)}
  ${chip(706, 1028, 'Occupied', '#fee2e2', colors.coral, 150)}
  ${text(204, 1130, 'Imran Shaikh', 26, 800)}
  ${chip(706, 1096, 'Free', colors.mint, colors.primary, 120)}
  ${rounded(154, 1260, 772, 240, 34, '#f8fafc', '#e8edf1')}
  ${text(204, 1324, 'Manage services, staff, and booking status', 30, 900)}
  ${text(204, 1384, 'Keep the shop side organized in one place.', 24, 600, colors.muted)}
  `;
  return phoneFrame(content, 'Run your salon', 'Manage listings, staff, revenue, and bookings.');
}

function barberSvg() {
  const content = `
  ${rounded(154, 430, 772, 210, 34, colors.ink, 'none', 0)}
  ${text(204, 504, 'Arjun Mane', 40, 900, '#fff')}
  ${text(204, 552, 'Fade specialist', 25, 600, '#d1d5db')}
  ${chip(204, 584, 'Assigned today', '#ffffff22', '#fff', 180)}
  ${text(154, 724, 'Next appointment', 34, 900)}
  ${rounded(154, 766, 772, 240, 34, '#fff', '#e8edf1')}
  ${text(204, 838, 'Rahul Sharma', 32, 900)}
  ${text(204, 884, 'Classic Haircut · 10:30 AM', 25, 600, colors.muted)}
  ${chip(204, 920, 'Confirmed', colors.mint, colors.primary, 150)}
  ${rounded(154, 1068, 772, 240, 34, '#fff', '#e8edf1')}
  ${text(204, 1138, 'Start work', 32, 900)}
  ${text(204, 1184, 'Update booking status as service progresses.', 24, 600, colors.muted)}
  ${chip(204, 1222, 'Start', '#eef2ff', colors.blue, 120)}
  ${chip(344, 1222, 'Done', colors.mint, colors.primary, 120)}
  ${rounded(154, 1390, 772, 160, 34, '#f8fafc', '#e8edf1')}
  ${text(204, 1454, 'Join salon teams', 30, 900)}
  ${text(204, 1500, 'Send requests and share your speciality.', 24, 600, colors.muted)}
  `;
  return phoneFrame(content, 'Barber tools', 'Track assigned customers and update work status.');
}

function featureGraphic() {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="500" viewBox="0 0 1024 500">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#f7fbf8"/>
      <stop offset="1" stop-color="#e7f6ef"/>
    </linearGradient>
  </defs>
  <rect width="1024" height="500" fill="url(#bg)"/>
  <circle cx="890" cy="90" r="170" fill="#dff7ef"/>
  <circle cx="820" cy="430" r="210" fill="#fff5df"/>
  ${logoMark(82, 116, 156)}
  ${text(82, 336, 'Pritze', 82, 900)}
  ${text(88, 386, 'Book salon and grooming appointments easily', 30, 700, colors.muted)}
  ${rounded(640, 84, 280, 332, 42, '#fff', '#dbe7e1', 2)}
  ${text(682, 150, 'Today', 26, 900)}
  ${rounded(682, 180, 196, 54, 22, colors.mint, 'none', 0)}
  ${text(780, 216, 'Haircut 10:30', 21, 800, colors.primary, 'middle')}
  ${rounded(682, 254, 196, 54, 22, '#fff4df', 'none', 0)}
  ${text(780, 290, 'Beard 12:00', 21, 800, '#9a5b00', 'middle')}
  ${rounded(682, 328, 196, 54, 22, '#eef2ff', 'none', 0)}
  ${text(780, 364, 'Spa 4:30', 21, 800, colors.blue, 'middle')}
  </svg>`;
}

const files = {
  'feature_graphic_1024x500.svg': featureGraphic(),
  'phone_01_discover.svg': discoverSvg(),
  'phone_02_booking.svg': bookingSvg(),
  'phone_03_owner_dashboard.svg': ownerSvg(),
  'phone_04_barber_tools.svg': barberSvg(),
};

for (const [name, svg] of Object.entries(files)) {
  writeFileSync(join(outDir, name), svg);
}
