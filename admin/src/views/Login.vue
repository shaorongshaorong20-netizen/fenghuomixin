<template>
  <div class="page">
    <div class="card">
      <div class="logo">烽火密信</div>
      <div class="sub">管理后台</div>

      <el-form :model="form" @submit.prevent>
        <el-form-item>
          <el-input v-model="form.username" placeholder="管理员账号" clearable />
        </el-form-item>
        <el-form-item>
          <el-input
            v-model="form.password"
            placeholder="密码"
            show-password
            type="password"
            @keyup.enter="onLogin"
          />
        </el-form-item>
        <el-button
          type="danger"
          size="large"
          class="btn"
          :loading="loading"
          :disabled="!form.username || !form.password"
          @click="onLogin"
        >
          登录
        </el-button>
      </el-form>
    </div>
  </div>
</template>

<script setup>
import { reactive, ref } from 'vue'
import { useRouter } from 'vue-router'
import { ElMessage } from 'element-plus'

import { adminLogin, fetchAdminMe, setAdminPermissions, setAdminProfile, setAdminRole, setAdminToken } from '../api'

const router = useRouter()
const loading = ref(false)
const form = reactive({ username: '', password: '' })

function normalizeLoginResult(data) {
  const token =
    data?.token ||
    data?.accessToken ||
    data?.data?.token ||
    data?.data?.accessToken ||
    ''
  const userId =
    data?.userId ||
    data?.id ||
    data?.data?.userId ||
    data?.data?.id ||
    data?.user?.id ||
    data?.data?.user?.id ||
    null
  return { token, userId }
}

async function onLogin() {
  if (loading.value) return
  loading.value = true
  try {
    const data = await adminLogin({
      username: form.username.trim(),
      password: form.password,
    })
    const { token, userId } = normalizeLoginResult(data)
    if (!token) throw new Error('登录失败：未返回 token')
    setAdminToken(token)
    setAdminProfile({ userId, username: form.username.trim() })
    try {
      const me = await fetchAdminMe()
      const role = me?.user?.role || me?.role || ''
      setAdminRole(role)
      setAdminPermissions(me?.permissions || {})
    } catch (_) {}
    router.replace('/dashboard')
  } catch (e) {
    const msg = e?.response?.data?.message || e?.message || '登录失败'
    ElMessage.error(String(msg))
  } finally {
    loading.value = false
  }
}
</script>

<style scoped>
.page {
  height: 100vh;
  display: grid;
  place-items: center;
  background: #080c14;
}

.card {
  width: min(420px, calc(100vw - 32px));
  padding: 24px;
  background: #0f131e;
  border: 1px solid #1a1f2e;
  border-radius: 16px;
}

.logo {
  color: #e8e8e8;
  font-size: 24px;
  font-weight: 800;
  letter-spacing: 6px;
  text-align: center;
}

.sub {
  margin-top: 10px;
  margin-bottom: 18px;
  color: #8b8b8b;
  font-size: 13px;
  text-align: center;
}

.btn {
  width: 100%;
}
</style>
