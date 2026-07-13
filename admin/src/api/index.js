import axios from 'axios'

const api = axios.create({
  baseURL: '',
  timeout: 15000,
})

api.interceptors.request.use((config) => {
  const token = localStorage.getItem('admin_token')
  if (token) {
    config.headers = config.headers ?? {}
    config.headers.Authorization = `Bearer ${token}`
  }
  return config
})

api.interceptors.response.use(
  (res) => res,
  (error) => {
    const status = error?.response?.status
    if (status === 401) {
      localStorage.removeItem('admin_token')
      localStorage.removeItem('admin_userId')
      localStorage.removeItem('admin_username')
      const loginPath = `${import.meta.env.BASE_URL}login`
      if (window.location.pathname !== loginPath) {
        window.location.href = loginPath
      }
    }
    return Promise.reject(error)
  },
)

export function setAdminToken(token) {
  localStorage.setItem('admin_token', token)
}

export function clearAdminSession() {
  localStorage.removeItem('admin_token')
  localStorage.removeItem('admin_userId')
  localStorage.removeItem('admin_username')
  localStorage.removeItem('admin_role')
  localStorage.removeItem('admin_permissions')
}

export function getAdminToken() {
  return localStorage.getItem('admin_token') || ''
}

export function setAdminProfile({ userId, username }) {
  if (userId != null) localStorage.setItem('admin_userId', String(userId))
  if (username) localStorage.setItem('admin_username', String(username))
}

export function getAdminUsername() {
  return localStorage.getItem('admin_username') || ''
}

export function setAdminRole(role) {
  if (role) localStorage.setItem('admin_role', String(role))
}

export function getAdminRole() {
  return localStorage.getItem('admin_role') || ''
}

export function setAdminPermissions(perms) {
  try {
    localStorage.setItem('admin_permissions', JSON.stringify(perms || {}))
  } catch (_) {}
}

export function getAdminPermissions() {
  try {
    const raw = localStorage.getItem('admin_permissions') || '{}'
    const p = JSON.parse(raw)
    return p && typeof p === 'object' ? p : {}
  } catch (_) {
    return {}
  }
}

export async function adminLogin({ username, password }) {
  const res = await api.post('/api/auth/login', { username, password })
  return res.data
}

export async function fetchAdminMe() {
  const res = await api.get('/api/admin/me')
  return res.data
}

export async function fetchAccounts() {
  const res = await api.get('/api/admin/accounts')
  return res.data
}

export async function createAccount({ username, password }) {
  const res = await api.post('/api/admin/accounts', { username, password })
  return res.data
}

export async function updateAccountStatus({ id, status }) {
  const next =
    status === 'active' || status === 'disabled'
      ? status
      : Number(status) === 1
        ? 'active'
        : 'disabled'
  const res = await api.put(`/api/admin/accounts/${id}/status`, { status: next })
  return res.data
}

export async function deleteAccount(id) {
  const res = await api.delete(`/api/admin/accounts/${id}`)
  return res.data
}

export async function fetchAdminMessages(params) {
  const res = await api.get('/api/admin/messages', { params })
  return res.data
}

export async function fetchAdminLogs() {
  const res = await api.get('/api/admin/logs')
  return res.data
}

export async function fetchAdmins() {
  const res = await api.get('/api/admin/admins')
  return res.data
}

export async function fetchAdminPermissions(id) {
  const res = await api.get(`/api/admin/admins/${id}/permissions`)
  return res.data
}

export async function fetchAdminSessions(id) {
  const res = await api.get(`/api/admin/admins/${id}/sessions`)
  return res.data
}

export async function fetchAdminLoginLogs(id) {
  const res = await api.get(`/api/admin/admins/${id}/login-logs`)
  return res.data
}

export async function kickAdmin(id) {
  const res = await api.post(`/api/admin/admins/${id}/kick`)
  return res.data
}

export async function createAdmin({ username, password }) {
  const res = await api.post('/api/admin/admins', { username, password })
  return res.data
}

export async function updateAdminStatus({ id, status }) {
  const next =
    status === 'active' || status === 'disabled'
      ? status
      : Number(status) === 1
        ? 'active'
        : 'disabled'
  const res = await api.put(`/api/admin/admins/${id}/status`, { status: next })
  return res.data
}

export async function deleteAdmin(id) {
  const res = await api.delete(`/api/admin/admins/${id}`)
  return res.data
}

export async function resetAdminPassword({ id, password }) {
  const res = await api.post(`/api/admin/admins/${id}/reset-password`, { password })
  return res.data
}

export async function updateAdminPermissions({ id, manageAccounts, viewAudit, viewLogs, maxAdminSessions }) {
  const res = await api.put(`/api/admin/admins/${id}/permissions`, {
    manageAccounts,
    viewAudit,
    viewLogs,
    maxAdminSessions,
  })
  return res.data
}

export async function changePassword({ oldPassword, newPassword }) {
  const res = await api.post('/api/user/change-password', { oldPassword, newPassword })
  return res.data
}
