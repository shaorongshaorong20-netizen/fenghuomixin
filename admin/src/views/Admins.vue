<template>
  <div class="page">
    <div class="toolbar">
      <div class="left">
        <el-tag type="danger" effect="dark">仅超级管理员可管理管理员账号</el-tag>
      </div>
      <div class="actions">
        <el-button type="danger" @click="openCreate">添加管理员</el-button>
        <el-button @click="load">刷新</el-button>
      </div>
    </div>

    <el-card class="card">
      <el-table :data="rows" v-loading="loading" style="width: 100%">
        <el-table-column prop="username" label="用户名" min-width="180" />
        <el-table-column prop="role" label="角色" width="140">
          <template #default="{ row }">
            <el-tag :type="row.role === 'super' ? 'danger' : row.role === 'admin' ? 'info' : 'warning'">
              {{ row.role === 'super' ? '超级管理员' : row.role === 'admin' ? '管理员' : '普通账号' }}
            </el-tag>
          </template>
        </el-table-column>
        <el-table-column label="权限" min-width="220">
          <template #default="{ row }">
            <el-tag v-if="row.role === 'super'" type="danger" effect="dark">全部</el-tag>
            <template v-else>
              <el-tag v-if="row.permissions?.manageAccounts" type="success">账号</el-tag>
              <el-tag v-if="row.permissions?.viewAudit" type="success">审计</el-tag>
              <el-tag v-if="row.permissions?.viewLogs" type="success">日志</el-tag>
              <el-tag v-if="row.permissions && !row.permissions.manageAccounts && !row.permissions.viewAudit && !row.permissions.viewLogs" type="info">
                无
              </el-tag>
              <el-tag v-if="row.permissions?.__defaultAll" type="info">默认</el-tag>
            </template>
          </template>
        </el-table-column>
        <el-table-column prop="last_login" label="最后登录时间" min-width="220" />
        <el-table-column label="最近登录地区" min-width="160">
          <template #default="{ row }">
            <span v-if="row.lastLoginCountry || row.lastLoginProvince">
              {{ [row.lastLoginCountry, row.lastLoginProvince].filter(Boolean).join(' / ') }}
            </span>
            <span v-else>-</span>
          </template>
        </el-table-column>
        <el-table-column label="在线设备" width="120">
          <template #default="{ row }">
            <el-tag :type="Number(row.onlineSessions || 0) > 0 ? 'success' : 'info'">
              {{ Number(row.onlineSessions || 0) }}
            </el-tag>
          </template>
        </el-table-column>
        <el-table-column label="状态" width="120">
          <template #default="{ row }">
            <el-tag :type="row.status === 'active' ? 'success' : 'info'">
              {{ row.status === 'active' ? '启用' : '禁用' }}
            </el-tag>
          </template>
        </el-table-column>
        <el-table-column label="操作" width="400" fixed="right">
          <template #default="{ row }">
            <el-button size="small" @click="openReset(row)" :disabled="row.username === 'admin'">
              重置密码
            </el-button>
            <el-button
              size="small"
              type="primary"
              plain
              @click="openPerms(row)"
              :disabled="row.username === 'admin' || row.role === 'super'"
            >
              权限
            </el-button>
            <el-button
              size="small"
              type="primary"
              plain
              @click="openMonitor(row)"
              :disabled="row.username === 'admin' || row.role === 'super'"
            >
              监控
            </el-button>
            <el-button size="small" @click="toggle(row)" :disabled="row.username === 'admin'">
              {{ row.status === 'active' ? '禁用' : '启用' }}
            </el-button>
            <el-button
              size="small"
              type="danger"
              plain
              @click="remove(row)"
              :disabled="row.username === 'admin'"
            >
              删除
            </el-button>
          </template>
        </el-table-column>
      </el-table>
    </el-card>

    <el-dialog v-model="createOpen" title="添加管理员" width="420px">
      <el-form :model="createForm" label-position="top">
        <el-form-item label="用户名">
          <el-input v-model="createForm.username" placeholder="请输入用户名" />
        </el-form-item>
        <el-form-item label="密码">
          <el-input v-model="createForm.password" placeholder="请输入密码" show-password />
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="createOpen = false">取消</el-button>
        <el-button
          type="danger"
          :loading="creating"
          :disabled="!createForm.username || !createForm.password"
          @click="create"
        >
          创建
        </el-button>
      </template>
    </el-dialog>

    <el-dialog v-model="resetOpen" title="重置密码" width="420px">
      <el-form :model="resetForm" label-position="top">
        <el-form-item label="新密码">
          <el-input v-model="resetForm.password" placeholder="请输入新密码" show-password />
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="resetOpen = false">取消</el-button>
        <el-button type="danger" :loading="resetting" :disabled="!resetForm.password" @click="reset">
          确认
        </el-button>
      </template>
    </el-dialog>

    <el-dialog v-model="permsOpen" title="设置权限" width="460px">
      <el-form :model="permsForm" label-position="top">
        <el-form-item label="管理员">
          <el-input v-model="permsForm.username" disabled />
        </el-form-item>
        <el-form-item label="权限">
          <el-checkbox v-model="permsForm.manageAccounts">App账号管理</el-checkbox>
          <el-checkbox v-model="permsForm.viewAudit">消息审计</el-checkbox>
          <el-checkbox v-model="permsForm.viewLogs">系统日志</el-checkbox>
        </el-form-item>
        <el-form-item label="最大在线设备数">
          <el-input-number v-model="permsForm.maxAdminSessions" :min="-1" :step="1" />
          <div class="hint">-1 表示不限制；0 表示禁止登录；正整数表示最多允许同时在线设备数</div>
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="permsOpen = false">取消</el-button>
        <el-button type="danger" :loading="permsSaving" @click="savePerms">保存</el-button>
      </template>
    </el-dialog>

    <el-dialog v-model="monitorOpen" title="子管理员监控" width="920px">
      <div class="monitorHeader">
        <div class="monitorTitle">
          {{ monitorAdmin?.username || '' }}
        </div>
        <div class="monitorActions">
          <el-button size="small" type="danger" plain :disabled="!monitorAdmin" @click="kickNow">
            立即下线
          </el-button>
          <el-button size="small" :disabled="!monitorAdmin" @click="loadMonitor">
            刷新
          </el-button>
        </div>
      </div>
      <el-tabs v-model="monitorTab">
        <el-tab-pane label="在线设备" name="sessions">
          <el-table :data="monitorSessions" v-loading="monitorLoading" style="width: 100%">
            <el-table-column prop="ip" label="IP" min-width="160" />
            <el-table-column label="地区" min-width="180">
              <template #default="{ row }">
                {{ [row.country, row.province].filter(Boolean).join(' / ') || '-' }}
              </template>
            </el-table-column>
            <el-table-column prop="connectedAt" label="连接时间" min-width="180" />
            <el-table-column prop="lastSeenAt" label="最近活跃" min-width="180" />
            <el-table-column label="状态" width="120">
              <template #default="{ row }">
                <el-tag :type="row.disconnectedAt ? 'info' : 'success'">
                  {{ row.disconnectedAt ? '已断开' : '在线' }}
                </el-tag>
              </template>
            </el-table-column>
          </el-table>
        </el-tab-pane>
        <el-tab-pane label="登录记录" name="logs">
          <el-table :data="monitorLogs" v-loading="monitorLoading" style="width: 100%">
            <el-table-column prop="createdAt" label="时间" min-width="180" />
            <el-table-column prop="ip" label="IP" min-width="160" />
            <el-table-column label="地区" min-width="180">
              <template #default="{ row }">
                {{ [row.country, row.province].filter(Boolean).join(' / ') || '-' }}
              </template>
            </el-table-column>
            <el-table-column prop="userAgent" label="UA" min-width="280" />
          </el-table>
        </el-tab-pane>
      </el-tabs>
    </el-dialog>
  </div>
</template>

<script setup>
import { onMounted, reactive, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'

import { createAdmin, deleteAdmin, fetchAdminLoginLogs, fetchAdminPermissions, fetchAdmins, fetchAdminSessions, kickAdmin, resetAdminPassword, updateAdminPermissions, updateAdminStatus } from '../api'

const loading = ref(false)
const rows = ref([])

const createOpen = ref(false)
const creating = ref(false)
const createForm = reactive({ username: '', password: '' })

const resetOpen = ref(false)
const resetting = ref(false)
const resetForm = reactive({ id: null, password: '' })

const permsOpen = ref(false)
const permsSaving = ref(false)
const permsForm = reactive({
  id: null,
  username: '',
  manageAccounts: true,
  viewAudit: true,
  viewLogs: true,
  maxAdminSessions: -1,
})

const monitorOpen = ref(false)
const monitorLoading = ref(false)
const monitorAdmin = ref(null)
const monitorSessions = ref([])
const monitorLogs = ref([])
const monitorTab = ref('sessions')

function normalize(data) {
  const list = Array.isArray(data) ? data : (data?.admins || data?.data || [])
  if (!Array.isArray(list)) return []
  return list.map((a) => ({
    id: a.id,
    username: a.username,
    role: (a.role || '').toString() || (a.username === 'admin' ? 'super' : 'user'),
    status: (a.status || 'active').toString(),
    last_login: a.last_login || a.lastLogin || '',
    onlineSessions: Number(a.online_sessions ?? a.onlineSessions ?? 0) || 0,
    lastLoginCountry: (a.last_login_country ?? a.lastLoginCountry ?? '').toString(),
    lastLoginProvince: (a.last_login_province ?? a.lastLoginProvince ?? '').toString(),
    permissions: (() => {
      if ((a.role || '').toString() === 'super' || a.username === 'admin') {
        return { manageAccounts: true, viewAudit: true, viewLogs: true, __defaultAll: false }
      }
      const hasAny =
        a.manage_accounts != null || a.view_audit != null || a.view_logs != null
      const p = {
        manageAccounts: hasAny ? Number(a.manage_accounts) === 1 : true,
        viewAudit: hasAny ? Number(a.view_audit) === 1 : true,
        viewLogs: hasAny ? Number(a.view_logs) === 1 : true,
        __defaultAll: !hasAny,
      }
      return p
    })(),
  }))
}

async function load() {
  loading.value = true
  try {
    const data = await fetchAdmins()
    rows.value = normalize(data)
  } catch (e) {
    const msg = e?.response?.data?.message || e?.message || '加载失败'
    ElMessage.error(String(msg))
  } finally {
    loading.value = false
  }
}

function openCreate() {
  createForm.username = ''
  createForm.password = ''
  createOpen.value = true
}

async function create() {
  if (creating.value) return
  creating.value = true
  try {
    await createAdmin({ username: createForm.username.trim(), password: createForm.password })
    ElMessage.success('创建成功')
    createOpen.value = false
    await load()
  } catch (e) {
    const msg = e?.response?.data?.message || e?.message || '创建失败'
    ElMessage.error(String(msg))
  } finally {
    creating.value = false
  }
}

async function toggle(row) {
  const next = row.status === 'active' ? 'disabled' : 'active'
  try {
    await updateAdminStatus({ id: row.id, status: next })
    ElMessage.success('已更新')
    await load()
  } catch (e) {
    const msg = e?.response?.data?.message || e?.message || '更新失败'
    ElMessage.error(String(msg))
  }
}

function openReset(row) {
  resetForm.id = row.id
  resetForm.password = ''
  resetOpen.value = true
}

function openPerms(row) {
  permsForm.id = row.id
  permsForm.username = row.username
  permsOpen.value = true
  permsSaving.value = true
  fetchAdminPermissions(row.id)
    .then((data) => {
      const p = data?.permissions || data?.data?.permissions || data || {}
      permsForm.manageAccounts = p.manageAccounts === true
      permsForm.viewAudit = p.viewAudit === true
      permsForm.viewLogs = p.viewLogs === true
      permsForm.maxAdminSessions =
        typeof p.maxAdminSessions === 'number' ? p.maxAdminSessions : Number(p.maxAdminSessions ?? -1)
    })
    .catch((e) => {
      const msg = e?.response?.data?.message || e?.message || '加载权限失败'
      ElMessage.error(String(msg))
      permsForm.manageAccounts = false
      permsForm.viewAudit = false
      permsForm.viewLogs = false
      permsForm.maxAdminSessions = -1
    })
    .finally(() => {
      permsSaving.value = false
    })
}

async function savePerms() {
  if (permsSaving.value) return
  permsSaving.value = true
  try {
    await updateAdminPermissions({
      id: permsForm.id,
      manageAccounts: permsForm.manageAccounts,
      viewAudit: permsForm.viewAudit,
      viewLogs: permsForm.viewLogs,
      maxAdminSessions: permsForm.maxAdminSessions,
    })
    ElMessage.success('已保存')
    permsOpen.value = false
    await load()
  } catch (e) {
    const msg = e?.response?.data?.message || e?.message || '保存失败'
    ElMessage.error(String(msg))
  } finally {
    permsSaving.value = false
  }
}

async function reset() {
  if (resetting.value) return
  resetting.value = true
  try {
    await resetAdminPassword({ id: resetForm.id, password: resetForm.password })
    ElMessage.success('已重置')
    resetOpen.value = false
  } catch (e) {
    const msg = e?.response?.data?.message || e?.message || '重置失败'
    ElMessage.error(String(msg))
  } finally {
    resetting.value = false
  }
}

async function remove(row) {
  try {
    await ElMessageBox.confirm(`确认删除管理员「${row.username}」？`, '删除管理员', {
      confirmButtonText: '删除',
      cancelButtonText: '取消',
      type: 'warning',
    })
  } catch (_) {
    return
  }

  try {
    await deleteAdmin(row.id)
    ElMessage.success('已删除')
    await load()
  } catch (e) {
    const msg = e?.response?.data?.message || e?.message || '删除失败'
    ElMessage.error(String(msg))
  }
}

function openMonitor(row) {
  monitorAdmin.value = row
  monitorOpen.value = true
  monitorTab.value = 'sessions'
  loadMonitor()
}

async function loadMonitor() {
  if (!monitorAdmin.value) return
  monitorLoading.value = true
  try {
    const [s, l] = await Promise.all([
      fetchAdminSessions(monitorAdmin.value.id),
      fetchAdminLoginLogs(monitorAdmin.value.id),
    ])
    monitorSessions.value = Array.isArray(s?.sessions) ? s.sessions : []
    monitorLogs.value = Array.isArray(l?.logs) ? l.logs : []
  } catch (e) {
    const msg = e?.response?.data?.message || e?.message || '加载失败'
    ElMessage.error(String(msg))
    monitorSessions.value = []
    monitorLogs.value = []
  } finally {
    monitorLoading.value = false
  }
}

async function kickNow() {
  if (!monitorAdmin.value) return
  try {
    await ElMessageBox.confirm(`确认让管理员「${monitorAdmin.value.username}」立即下线？`, '立即下线', {
      confirmButtonText: '下线',
      cancelButtonText: '取消',
      type: 'warning',
    })
  } catch (_) {
    return
  }
  try {
    await kickAdmin(monitorAdmin.value.id)
    ElMessage.success('已下线')
    await load()
    await loadMonitor()
  } catch (e) {
    const msg = e?.response?.data?.message || e?.message || '操作失败'
    ElMessage.error(String(msg))
  }
}

onMounted(load)
</script>

<style scoped>
.page {
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.toolbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  flex-wrap: wrap;
}

.actions {
  display: flex;
  gap: 10px;
}

.card {
  border-radius: 16px;
}

.hint {
  color: rgba(255, 255, 255, 0.55);
  font-size: 12px;
  margin-top: 6px;
}

.monitorHeader {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  margin-bottom: 10px;
}

.monitorTitle {
  font-weight: 800;
}

.monitorActions {
  display: flex;
  gap: 10px;
}
</style>
