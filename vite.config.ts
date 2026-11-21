import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { VitePWA } from 'vite-plugin-pwa'

export default defineConfig({
  server: { host: '0.0.0.0' },
  plugins: [
    react(),
    VitePWA({
      registerType: 'autoUpdate',
      manifest: {
        name: 'FootBid Football Auction',
        short_name: 'FootBid',
        description: 'Build your all-time football squad at auction.',
        theme_color: '#10150f',
        background_color: '#10150f',
        display: 'standalone',
        start_url: '/',
        icons: [
          { src: '/footbid-192.png', sizes: '192x192', type: 'image/png' },
          { src: '/footbid-512.png', sizes: '512x512', type: 'image/png' }
        ]
      }
    })
  ]
})
