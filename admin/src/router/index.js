import { createRouter, createWebHistory } from 'vue-router'
import { getAdminPermissions, getAdminRole, getAdminToken } from '../api'

import Login from '../views/Login.vue'
import Dashboard from '../views/Dashboard.vue'
import Accounts from '../views/Accounts.vue'
import Audit from '../views/Audit.vue'
import Logs from '../views/Logs.vue'
import Admins from '../views/Admins.vue'

const routes = [
  { path: '/', redirect: '/dashboard' },
  { path: '/login', name: 'login', component: Login, meta: { public: true } },
  { path: '/dashboard', name: 'dashboard', component: Dashboard },
  { path: '/accounts', name: 'accounts', component: Accounts, meta: { perm: 'manageAccounts' } },
  { path: '/audit', name: 'audit', component: Audit, meta: { perm: 'viewAudit' } },
  { path: '/logs', name: 'logs', component: Logs, meta: { perm: 'viewLogs' } },
  { path: '/admins', name: 'admins', component: Admins, meta: { perm: 'superOnly' } },
]

const router = createRouter({
  history: createWebHistory(import.meta.env.BASE_URL),
  routes,
})

router.beforeEach((to) => {
  if (to.meta.public) return true
  const token = getAdminToken()
  if (!token) return { path: '/login' }
  const role = getAdminRole()
  if (to.meta.perm) {
    if (role === 'super') return true
    if (to.meta.perm === 'superOnly') return { path: '/dashboard' }
    const perms = getAdminPermissions()
    if (perms && perms[to.meta.perm] === true) return true
    return { path: '/dashboard' }
  }
  return true
})

export default router
