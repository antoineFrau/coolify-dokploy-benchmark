export const metadata = { title: "Benchmark app" };

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body
        style={{
          fontFamily: "system-ui, sans-serif",
          margin: 0,
          padding: "2rem",
        }}
      >
        {children}
      </body>
    </html>
  );
}
