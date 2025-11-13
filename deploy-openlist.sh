#!/bin/bash

# OpenList 自动部署脚本
# 基于 steps.md 中的部署步骤

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 默认配置
DEFAULT_NETWORK="xifan"
DEFAULT_SUBNET="10.0.0.1/16"
DEFAULT_IP_START=10
DEFAULT_PORT_START=3000
DEFAULT_USERNAME="admin"
DEFAULT_PASSWORD="password"
DEFAULT_TAG="latest"
OPENLIST_IMAGE="openlistteam/openlist"

# 函数：打印信息
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 函数：检查 Docker 是否安装
check_docker() {
    if ! command -v docker &> /dev/null; then
        log_error "Docker 未安装，请先安装 Docker"
        exit 1
    fi
    log_info "Docker 已安装: $(docker --version)"
}

# 函数：创建或检查 Docker 网络
setup_network() {
    local network_name=$1
    local subnet=$2

    if docker network inspect "$network_name" &> /dev/null; then
        log_info "Docker 网络 '$network_name' 已存在"
    else
        log_info "创建 Docker 网络 '$network_name' (子网: $subnet)"
        docker network create --subnet="$subnet" "$network_name"
    fi
}

# 函数：查找可用的 IP 地址
find_available_ip() {
    local network_name=$1
    local subnet=$2
    local start_ip=$3

    # 提取网段前缀（例如：172.20.0）
    local subnet_prefix=$(echo "$subnet" | cut -d'/' -f1 | cut -d'.' -f1-3)

    # 获取已使用的 IP
    local used_ips=$(docker network inspect "$network_name" 2>/dev/null | grep -oP '"IPv4Address": "\K[^/]+' | cut -d'.' -f4 | sort -n)

    # 查找可用的 IP
    local test_ip=$start_ip
    while true; do
        local full_ip="${subnet_prefix}.${test_ip}"
        if ! echo "$used_ips" | grep -q "^${test_ip}$"; then
            echo "$full_ip"
            return
        fi
        test_ip=$((test_ip + 1))
        if [ $test_ip -gt 254 ]; then
            log_error "网段内无可用 IP"
            exit 1
        fi
    done
}

# 函数：查找可用的端口
find_available_port() {
    # 获取 Docker 容器当前使用的最高端口
    local max_port=$(docker ps --format '{{.Ports}}' | grep -oP '\d+(?=->)' | sort -n | tail -1)

    if [ -n "$max_port" ]; then
        # 最高端口+1
        echo $((max_port + 1))
    else
        # 没有容器运行，使用默认起始端口
        echo "$DEFAULT_PORT_START"
    fi
}

# 函数：部署 OpenList 容器
deploy_openlist() {
    local container_name=$1
    local network=$2
    local ip=$3
    local port=$4
    local data_path=$5
    local username=$6
    local password=$7
    local image_tag=$8

    log_info "开始部署 OpenList 容器..."
    log_info "  容器名称: $container_name"
    log_info "  网络: $network"
    log_info "  IP: $ip"
    log_info "  端口: $port"
    log_info "  数据路径: $data_path"
    log_info "  镜像版本: $image_tag"

    # 创建数据目录
    mkdir -p "$data_path"

    # 启动容器
    docker run -d \
        --name "$container_name" \
        --network "$network" \
        --ip "$ip" \
        -p "${port}:5244" \
        -v "${data_path}:/opt/alist/data" \
        -e PUID=0 \
        -e PGID=0 \
        -e UMASK=022 \
        --restart unless-stopped \
        "${OPENLIST_IMAGE}:${image_tag}"

    log_info "容器已启动，等待服务就绪..."
    sleep 8

    # 设置管理员密码
    log_info "设置管理员密码为: $password"
    docker exec "$container_name" /opt/openlist/openlist admin set "$password" || log_warn "设置密码失败"

    log_info "容器部署完成！"
}

# 函数：通过 API 自动配置 OpenList
auto_configure_openlist() {
    local port=$1
    local username=$2
    local password=$3

    log_info "开始通过 API 自动配置 OpenList..."

    # 检查 jq 是否安装
    if ! command -v jq &> /dev/null; then
        log_warn "jq 未安装，跳过自动配置。请手动完成步骤 9-12"
        return 1
    fi

    local base_url="http://localhost:${port}"

    # 等待服务完全启动
    log_info "等待服务完全启动..."
    local max_attempts=30
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        if curl -s -f "${base_url}/api/public/settings" > /dev/null 2>&1; then
            break
        fi
        sleep 2
        attempt=$((attempt + 1))
    done

    if [ $attempt -eq $max_attempts ]; then
        log_warn "服务启动超时，跳过自动配置"
        return 1
    fi

    # 登录获取 token
    log_info "登录 OpenList API..."
    local login_response=$(curl -s -X POST "${base_url}/api/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${username}\",\"password\":\"${password}\"}")

    local token=$(echo "$login_response" | jq -r '.data.token')

    if [ -z "$token" ] || [ "$token" = "null" ]; then
        log_error "登录失败: $(echo $login_response | jq -r '.message')"
        return 1
    fi

    log_info "登录成功"

    # 步骤 9: 启用 guest 用户
    log_info "步骤 9: 启用 guest 用户..."
    curl -s -X POST "${base_url}/api/admin/user/update" \
        -H "Authorization: ${token}" \
        -H "Content-Type: application/json" \
        -d '{"id":2,"username":"guest","password":"","base_path":"/","role":1,"disabled":false,"permission":0}' > /dev/null
    log_info "  guest 用户已启用"

    # 步骤 10: 关闭全局签名
    log_info "步骤 10: 关闭全局签名..."
    curl -s -X POST "${base_url}/api/admin/setting/save" \
        -H "Authorization: ${token}" \
        -H "Content-Type: application/json" \
        -d '[{"key":"sign_all","value":"false"}]' > /dev/null
    log_info "  全局签名已关闭"

    # 步骤 11: 配置隐藏文件
    log_info "步骤 11: 配置隐藏文件..."
    local hide_files="/\\\\/README.md/i\\n/\\\\/Attachments/i"
    curl -s -X POST "${base_url}/api/admin/setting/save" \
        -H "Authorization: ${token}" \
        -H "Content-Type: application/json" \
        -d "[{\"key\":\"hide_files\",\"value\":\"${hide_files}\"}]" > /dev/null
    log_info "  隐藏文件规则已配置"

    # 步骤 12: 配置自定义头部
    log_info "步骤 12: 配置自定义头部..."

    # 读取自定义头部内容（从脚本内嵌的内容）
    local custom_head=$(cat << 'CUSTOM_HEAD_EOF'
<script src="https://cdn.jsdelivr.net/npm/xlsx@0.18.5/dist/xlsx.mini.min.js"></script>
<script src=" https://cdnjs.cloudflare.com/ajax/libs/FileSaver.js/2.0.2/FileSaver.min.js"></script>
<script>
  (function () {
    "use strict";
    function debounce(func, wait) {
      let timeout;
      return function () {
        let context = this;
        let args = arguments;
        clearTimeout(timeout);
        timeout = setTimeout(function () {
          func.apply(context, args);
        }, wait);
      };
    }

    function exportExcelUi() {
      let centerToolbar = document.querySelector(".center-toolbar");
      if (centerToolbar) {
        let div = centerToolbar.querySelector("div");
        let excelBtn = `
          <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" t="1706073712360" class="toolbar-copy hope-icon hope-c-XNyZK hope-c-PJLV hope-c-PJLV-ifWVHXq-css" height = "1em" width="1em" viewBox="0 0 1024 1024" version="1.1" p-id="5169">
              <path d="M169.658182 1024C114.222545 1024 69.818182 978.385455 69.818182 922.717091V101.282909C69.818182 45.614545 114.222545 0 169.658182 0h523.170909l240.034909 246.690909V930.909091a93.090909 93.090909 0 0 1-93.090909 93.090909H169.658182zM653.498182 93.090909H169.658182C166.167273 93.090909 162.909091 96.488727 162.909091 101.282909v821.434182c0 4.794182 3.304727 8.192 6.749091 8.192h670.114909V284.485818L653.544727 93.090909z" fill="#2CB18D" p-id="5170"/>
              <path d="M315.019636 439.016727h79.872L488.727273 579.770182l93.835636-140.753455h79.872l-134.609454 192.698182L671.371636 837.818182h-79.872L488.727273 683.659636 385.954909 837.818182H306.082909l142.429091-206.103273z" fill="#2CB18D" p-id="5171"/>
              <path d="M256 139.636364h372.363636a46.545455 46.545455 0 0 1 46.545455 46.545454v46.545455a46.545455 46.545455 0 0 1-46.545455 46.545454H256a46.545455 46.545455 0 0 1-46.545455-46.545454V186.181818a46.545455 46.545455 0 0 1 46.545455-46.545454z m0 93.090909h372.363636V186.181818H256v46.545455z" fill="#2CB18D" p-id="5172"/>
              <path d="M395.636364 139.636364H349.090909v139.636363h46.545455zM535.272727 139.636364H488.727273v139.636363h46.545454zM233.332364 349.090909h418.909091a23.272727 23.272727 0 1 0 0-46.545454h-418.909091a23.272727 23.272727 0 0 0 0 46.545454z" fill="#2CB18D" p-id="5173"/>
          </svg>
              `;
        let parser = new DOMParser();
        let svgElement = parser.parseFromString(
          excelBtn,
          "image/svg+xml"
        ).documentElement;
        let tooltip = document.createElement("div");
        tooltip.style.display = "none";
        tooltip.style.position = "absolute";
        tooltip.style.background = "#333";
        tooltip.style.color = "#fff";
        tooltip.style.padding = "5px";
        tooltip.style.borderRadius = "5px";
        tooltip.style.fontSize = "13px";
        tooltip.textContent = "导出直链";

        let style = document.createElement("style");
        style.innerHTML = `
          #tooltip::after {
          content: "";
          position: absolute;
          top: 100%;
          left: 50%;
          margin-left: -5px;
          border-width: 5px;
          border-style: solid;
          border-color: #333 transparent transparent transparent;
          }
       `;
        document.head.appendChild(style);
        tooltip.id = "tooltip";
        svgElement.addEventListener(
          "mouseover",
          debounce(function (event) {
            let rect = svgElement.getBoundingClientRect();
            tooltip.style.display = "block";
            tooltip.style.left =
              window.scrollX + rect.left + rect.width / 2 - 30 + "px";
            tooltip.style.top = window.scrollY + rect.top - 32 + "px";
          }, 10)
        );

        svgElement.addEventListener(
          "mouseout",
          debounce(function () {
            tooltip.style.display = "none";
          }, 10)
        );
        let sixthElement = div.children[5];
        if (sixthElement) {
          div.insertBefore(svgElement, sixthElement);
        } else {
          div.appendChild(svgElement);
        }
        document.body.appendChild(tooltip);
        svgElement.addEventListener("click", function () {
          let list = Array.from(document.querySelectorAll(".list-item"));

          let checkedList = list.filter((item) => {
            let checkbox = item.querySelector('input[type="checkbox"]');
            return checkbox && checkbox.checked;
          });
          let result = [];
          for (let item of checkedList) {
            let nameElement = item.querySelector("p.name");
            if (nameElement.textContent.includes(".")) {
              let originalHref = item.href;
              let directLink = originalHref.replace(
                window.location.origin,
                `${window.location.origin}/d`
              );

              try {
                let url = new URL(directLink);
                url.pathname = encodeURI(decodeURI(url.pathname));
                directLink = url.toString();
              } catch (e) {
                console.warn('URL 编码失败，使用原始链接:', e);
              }

              result.push({
                标题: nameElement.textContent,
                直链: directLink,
              });
            } else {
              alert(`${nameElement.textContent} 不是文件，无法导出直链}`);
            }
          }
          if (result.length > 0) {
            let worksheet = XLSX.utils.json_to_sheet(result);
            let workbook = XLSX.utils.book_new();
            XLSX.utils.book_append_sheet(workbook, worksheet, "Sheet1");
            let excelBuffer = XLSX.write(workbook, {
              type: "array",
              bookType: "xlsx",
            });
            let excelBlob = new Blob([excelBuffer], { type: "application/xlsx" });
            saveAs(excelBlob, "直链.xlsx");
            alert("导出成功");
          }
        });
      }
    }
    document.addEventListener("DOMContentLoaded", function () {
      var callback = function (mutationsList, observer) {
        for (let mutation of mutationsList) {
          if (mutation.type === "childList") {
            for (let node of mutation.addedNodes) {
              if (
                node.nodeType === Node.ELEMENT_NODE &&
                node.matches(".center-toolbar")
              ) {
                exportExcelUi();
              }
            }
          }
        }
      };

      var observer = new MutationObserver(callback);
      var config = { childList: true, subtree: true };

      if (document.body) {
        observer.observe(document.body, config);
      } else {
        console.error("document.body is not available");
      }
    });
  })();
</script>
<!-- 去除底部信息 -->
<style>
  .footer a:first-of-type,
  .footer span:first-of-type {
    display: none;
  }
</style>
CUSTOM_HEAD_EOF
)

    # 使用 jq 来正确转义 JSON
    local json_payload=$(jq -n --arg value "$custom_head" '[{key: "customize_head", value: $value}]')

    curl -s -X POST "${base_url}/api/admin/setting/save" \
        -H "Authorization: ${token}" \
        -H "Content-Type: application/json" \
        -d "$json_payload" > /dev/null
    log_info "  自定义头部已配置"

    log_info "API 自动配置完成"
    return 0
}

# 主函数
main() {
    echo "========================================"
    echo "  OpenList 自动部署脚本"
    echo "========================================"
    echo ""

    # 检查是否提供客户标识
    if [ -z "$1" ]; then
        log_error "请提供客户标识（username）"
        echo "使用方法: $0 <客户标识> [tag] [网络名称] [子网]"
        echo "示例: $0 john"
        echo "      $0 john v4.0.5"
        echo ""
        echo "将创建："
        echo "  - 容器名称: alist-<客户标识>"
        echo "  - 数据路径: ~/docker/alist/<客户标识>/data"
        exit 1
    fi

    # 解析参数
    CLIENT_ID="$1"
    CONTAINER_NAME="alist-${CLIENT_ID}"
    DATA_PATH="$HOME/docker/alist/${CLIENT_ID}/data"
    IMAGE_TAG="${2:-$DEFAULT_TAG}"
    NETWORK="${3:-$DEFAULT_NETWORK}"
    SUBNET="${4:-$DEFAULT_SUBNET}"
    USERNAME="$DEFAULT_USERNAME"
    PASSWORD="$DEFAULT_PASSWORD"

    log_info "客户标识: $CLIENT_ID"
    log_info "容器名称: $CONTAINER_NAME"
    log_info "数据路径: $DATA_PATH"
    log_info "镜像版本: $IMAGE_TAG"

    # 检查环境
    log_info "检查 Docker 环境..."
    check_docker

    # 设置网络
    log_info "设置 Docker 网络..."
    setup_network "$NETWORK" "$SUBNET"

    # 查找可用 IP
    log_info "查找可用 IP 地址..."
    CONTAINER_IP=$(find_available_ip "$NETWORK" "$SUBNET" "$DEFAULT_IP_START")
    log_info "分配 IP: $CONTAINER_IP"

    # 查找可用端口
    log_info "查找可用端口..."
    CONTAINER_PORT=$(find_available_port)
    log_info "分配端口: $CONTAINER_PORT"

    # 检查容器是否已存在
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log_warn "容器 '$CONTAINER_NAME' 已存在"
        read -p "是否删除并重新部署? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            docker rm -f "$CONTAINER_NAME"
        else
            log_info "取消部署"
            exit 0
        fi
    fi

    # 部署容器
    deploy_openlist "$CONTAINER_NAME" "$NETWORK" "$CONTAINER_IP" "$CONTAINER_PORT" "$DATA_PATH" "$USERNAME" "$PASSWORD" "$IMAGE_TAG"

    # 通过 API 自动配置
    log_info "开始自动配置..."
    if auto_configure_openlist "$CONTAINER_PORT" "$USERNAME" "$PASSWORD"; then
        log_info "自动配置成功，已完成步骤 9-12"
    else
        log_warn "自动配置失败或被跳过，请手动完成步骤 9-12"
    fi

    echo ""
    echo "========================================"
    log_info "部署完成！"
    echo "========================================"
    echo ""
    log_info "访问地址: http://localhost:$CONTAINER_PORT"
    log_info "管理员账号: $USERNAME"
    log_info "管理员密码: $PASSWORD"
    echo ""
}

# 显示使用说明
if [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
    echo "OpenList 多客户部署脚本"
    echo ""
    echo "使用方法: $0 <客户标识> [tag] [网络名称] [子网]"
    echo ""
    echo "参数说明："
    echo "  客户标识  - 用于标识不同客户的标识符（必填）"
    echo "  tag       - Docker 镜像标签 (默认: latest，可选: v4.0.5, v4.1.0 等)"
    echo "  网络名称  - Docker 网络名称 (默认: xifan)"
    echo "  子网      - Docker 网络子网 (默认: 10.0.0.1/16)"
    echo ""
    echo "自动配置："
    echo "  - 容器名称: alist-<客户标识>"
    echo "  - 数据路径: ~/docker/alist/<客户标识>/data"
    echo "  - 管理员账号: admin"
    echo "  - 自动分配可用的 IP 和端口"
    echo ""
    echo "示例："
    echo "  $0 john              # 使用 latest 版本部署"
    echo "  $0 john v4.0.5       # 使用稳定版本 v4.0.5"
    echo "  $0 company1 latest   # 明确指定 latest 版本"
    echo "  $0 test v4.1.0 xifan # 指定版本和网络"
    exit 0
fi

# 执行主函数
main "$@"
