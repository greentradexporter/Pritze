import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Pritze Control Center",
  description: "Real-time salon operations and booking supervision for Pritze.",
  icons: {
    icon: "/pritze-icon.png",
    shortcut: "/pritze-icon.png",
    apple: "/pritze-icon.png",
  },
  openGraph: {
    title: "Pritze Control Center",
    description: "Real-time salon operations and booking supervision for Pritze.",
    type: "website",
  },
  twitter: {
    card: "summary",
    title: "Pritze Control Center",
    description: "Real-time salon operations and booking supervision for Pritze.",
  },
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en"><body>{children}</body></html>;
}
