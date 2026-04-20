import './globals.css';
import React from 'react';

export const metadata = { title: 'OpenVelox', description: 'Real-time Data Lakehouse Dashboard' };
export default function RootLayout({ children }: { children: React.ReactNode }) {
  return <html lang="en"><body>{children}</body></html>;
}
